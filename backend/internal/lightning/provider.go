package lightning

import (
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	defaultEastBaseURL = "https://noaa-goes19.s3.amazonaws.com"
	defaultWestBaseURL = "https://noaa-goes18.s3.amazonaws.com"
	maxListBodyBytes   = 2 << 20
	maxListPages       = 4
	maxLiveRetention   = 2 * time.Minute
	maxLiveFlashes     = 100000
	maxObjectBytes     = 32 << 20
)

type ProviderOptions struct {
	Enabled        bool
	EastBaseURL    string
	WestBaseURL    string
	PollInterval   time.Duration
	Retention      time.Duration
	MaxObjectBytes int64
	MaxFlashes     int
	SeamLongitude  float64
	UserAgent      string
	Client         *http.Client
	Logger         *slog.Logger
	Service        *Service
	Decoder        Decoder
	Now            func() time.Time
}

type source struct {
	id      string
	baseURL string
}

type Provider struct {
	enabled        bool
	sources        []source
	pollInterval   time.Duration
	retention      time.Duration
	maxObjectBytes int64
	userAgent      string
	client         *http.Client
	logger         *slog.Logger
	service        *Service
	decoder        Decoder
	now            func() time.Time

	mu          sync.Mutex
	seen        map[string]time.Time
	lastWarning map[string]time.Time
}

func NewProvider(options ProviderOptions) *Provider {
	if options.EastBaseURL == "" {
		options.EastBaseURL = defaultEastBaseURL
	}
	if options.WestBaseURL == "" {
		options.WestBaseURL = defaultWestBaseURL
	}
	if options.PollInterval <= 0 {
		options.PollInterval = 5 * time.Second
	} else if options.PollInterval < 2*time.Second {
		options.PollInterval = 2 * time.Second
	} else if options.PollInterval > 30*time.Second {
		options.PollInterval = 30 * time.Second
	}
	if options.Retention <= 0 {
		options.Retention = 90 * time.Second
	} else if options.Retention > maxLiveRetention {
		options.Retention = maxLiveRetention
	}
	if options.MaxObjectBytes <= 0 {
		options.MaxObjectBytes = 8 << 20
	} else if options.MaxObjectBytes > maxObjectBytes {
		options.MaxObjectBytes = maxObjectBytes
	}
	if options.MaxFlashes <= 0 {
		options.MaxFlashes = 20000
	} else if options.MaxFlashes > maxLiveFlashes {
		options.MaxFlashes = maxLiveFlashes
	}
	if options.Client == nil {
		options.Client = &http.Client{Timeout: 8 * time.Second}
	}
	if options.Logger == nil {
		options.Logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	if options.Service == nil {
		options.Service = NewService(ServiceOptions{Retention: options.Retention, MaxFlashes: options.MaxFlashes, SeamLongitude: options.SeamLongitude})
	}
	if options.Decoder == nil {
		options.Decoder = NetCDFDecoder{MaxFlashes: options.MaxFlashes, SeamLongitude: options.SeamLongitude}
	}
	if options.Now == nil {
		options.Now = time.Now
	}
	return &Provider{
		enabled: options.Enabled,
		sources: []source{
			{id: EastSourceID, baseURL: strings.TrimRight(options.EastBaseURL, "/")},
			{id: WestSourceID, baseURL: strings.TrimRight(options.WestBaseURL, "/")},
		},
		pollInterval:   options.PollInterval,
		retention:      options.Retention,
		maxObjectBytes: options.MaxObjectBytes,
		userAgent:      options.UserAgent,
		client:         options.Client,
		logger:         options.Logger,
		service:        options.Service,
		decoder:        options.Decoder,
		now:            options.Now,
		seen:           make(map[string]time.Time),
		lastWarning:    make(map[string]time.Time),
	}
}

func (p *Provider) Run(ctx context.Context) {
	if !p.enabled {
		return
	}
	var waitGroup sync.WaitGroup
	for _, currentSource := range p.sources {
		currentSource := currentSource
		waitGroup.Add(1)
		go func() {
			defer waitGroup.Done()
			p.runSource(ctx, currentSource)
		}()
	}
	waitGroup.Wait()
}

func (p *Provider) runSource(ctx context.Context, currentSource source) {
	p.pollAndLog(ctx, currentSource)
	ticker := time.NewTicker(p.pollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			p.pollAndLog(ctx, currentSource)
		}
	}
}

func (p *Provider) pollAndLog(ctx context.Context, currentSource source) {
	now := p.now().UTC()
	if err := p.pollSource(ctx, currentSource, now); err != nil && !errors.Is(err, context.Canceled) {
		p.mu.Lock()
		last := p.lastWarning[currentSource.id]
		if now.Sub(last) >= time.Minute {
			p.lastWarning[currentSource.id] = now
			p.logger.Warn("live lightning refresh failed", "satellite", SatelliteName(currentSource.id), "error", err)
		}
		p.mu.Unlock()
	}
}

func (p *Provider) pollSource(ctx context.Context, currentSource source, now time.Time) error {
	prefixes := livePrefixes(now, p.retention)
	listed := make([]listedObject, 0, 32)
	for _, prefix := range prefixes {
		objects, err := p.listObjects(ctx, currentSource, prefix)
		if err != nil {
			return err
		}
		listed = append(listed, objects...)
	}
	candidates := make([]objectCandidate, 0, len(listed))
	cutoff := now.Add(-p.retention)
	for _, listedObject := range listed {
		object, err := ParseObjectKey(listedObject.Key, currentSource.id)
		if err != nil || listedObject.Size <= 0 || listedObject.Size > p.maxObjectBytes {
			continue
		}
		if !object.End.After(cutoff) || object.End.After(now.Add(30*time.Second)) || object.Created.After(now.Add(30*time.Second)) {
			continue
		}
		if p.wasSeen(object.Key) {
			continue
		}
		candidates = append(candidates, objectCandidate{object: object, size: listedObject.Size})
	}
	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].object.End.Equal(candidates[j].object.End) {
			return candidates[i].object.Key < candidates[j].object.Key
		}
		return candidates[i].object.End.Before(candidates[j].object.End)
	})

	var failures []error
	for _, candidate := range candidates {
		body, err := p.downloadObject(ctx, currentSource, candidate)
		if err != nil {
			failures = append(failures, err)
			continue
		}
		receivedAt := p.now().UTC()
		flashes, err := p.decoder.Decode(body, candidate.object, receivedAt)
		if err != nil {
			failures = append(failures, fmt.Errorf("decode %s: %w", candidate.object.Key, err))
			continue
		}
		if !p.service.Ingest(Batch{Source: currentSource.id, ObjectKey: candidate.object.Key, ObjectEnd: candidate.object.End, Flashes: flashes}, receivedAt) {
			failures = append(failures, fmt.Errorf("ingest %s: object was rejected", candidate.object.Key))
			continue
		}
		p.markSeen(candidate.object.Key, candidate.object.End)
	}
	p.pruneSeen(now)
	// A successful LIST is connectivity/check provenance only. Product health
	// advances exclusively through a successfully decoded and ingested object.
	p.service.MarkChecked(currentSource.id, now)
	if len(failures) > 0 {
		return errors.Join(failures...)
	}
	return nil
}

type listBucketResult struct {
	IsTruncated           bool           `xml:"IsTruncated"`
	NextContinuationToken string         `xml:"NextContinuationToken"`
	Contents              []listedObject `xml:"Contents"`
}

type listedObject struct {
	Key  string `xml:"Key"`
	Size int64  `xml:"Size"`
}

type objectCandidate struct {
	object Object
	size   int64
}

func (p *Provider) listObjects(ctx context.Context, currentSource source, prefix string) ([]listedObject, error) {
	continuation := ""
	result := make([]listedObject, 0, 180)
	for page := 0; page < maxListPages; page++ {
		endpoint, err := url.Parse(currentSource.baseURL)
		if err != nil {
			return nil, fmt.Errorf("parse lightning source URL: %w", err)
		}
		query := endpoint.Query()
		query.Set("list-type", "2")
		query.Set("prefix", prefix)
		if continuation != "" {
			query.Set("continuation-token", continuation)
		}
		endpoint.RawQuery = query.Encode()
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
		if err != nil {
			return nil, err
		}
		p.decorateRequest(request)
		response, err := p.client.Do(request)
		if err != nil {
			return nil, fmt.Errorf("list %s objects: %w", SatelliteName(currentSource.id), err)
		}
		body, readErr := readBounded(response.Body, maxListBodyBytes)
		response.Body.Close()
		if readErr != nil {
			return nil, fmt.Errorf("read %s object list: %w", SatelliteName(currentSource.id), readErr)
		}
		if response.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("list %s objects: upstream status %d", SatelliteName(currentSource.id), response.StatusCode)
		}
		var decoded listBucketResult
		if err := xml.Unmarshal(body, &decoded); err != nil {
			return nil, fmt.Errorf("decode %s object list: %w", SatelliteName(currentSource.id), err)
		}
		result = append(result, decoded.Contents...)
		if !decoded.IsTruncated {
			return result, nil
		}
		continuation = strings.TrimSpace(decoded.NextContinuationToken)
		if continuation == "" {
			return nil, errors.New("truncated lightning object list omitted continuation token")
		}
	}
	return nil, errors.New("lightning object list exceeded pagination limit")
}

func (p *Provider) downloadObject(ctx context.Context, currentSource source, candidate objectCandidate) ([]byte, error) {
	endpoint := currentSource.baseURL + "/" + candidate.object.Key
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	p.decorateRequest(request)
	response, err := p.client.Do(request)
	if err != nil {
		return nil, fmt.Errorf("download %s: %w", candidate.object.Key, err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("download %s: upstream status %d", candidate.object.Key, response.StatusCode)
	}
	if response.ContentLength > p.maxObjectBytes || candidate.size > p.maxObjectBytes {
		return nil, fmt.Errorf("download %s: object exceeds size limit", candidate.object.Key)
	}
	body, err := readBounded(response.Body, p.maxObjectBytes)
	if err != nil {
		return nil, fmt.Errorf("download %s: %w", candidate.object.Key, err)
	}
	return body, nil
}

func (p *Provider) decorateRequest(request *http.Request) {
	request.Header.Set("Accept", "application/xml,application/x-netcdf,application/octet-stream")
	if p.userAgent != "" {
		request.Header.Set("User-Agent", p.userAgent)
	}
}

func readBounded(reader io.Reader, limit int64) ([]byte, error) {
	limited := io.LimitReader(reader, limit+1)
	body, err := io.ReadAll(limited)
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > limit {
		return nil, errors.New("response exceeds size limit")
	}
	return body, nil
}

func livePrefixes(now time.Time, retention time.Duration) []string {
	now = now.UTC()
	if retention <= 0 {
		retention = 90 * time.Second
	} else if retention > maxLiveRetention {
		retention = maxLiveRetention
	}
	oldestHour := now.Add(-retention).Truncate(time.Hour)
	currentHour := now.Truncate(time.Hour)
	prefixes := make([]string, 0, 2)
	for hour := oldestHour; !hour.After(currentHour); hour = hour.Add(time.Hour) {
		prefixes = append(prefixes, hourPrefix(hour))
	}
	return prefixes
}

func hourPrefix(value time.Time) string {
	return "GLM-L2-LCFA/" + value.Format("2006/") + fmt.Sprintf("%03d/", value.YearDay()) + value.Format("15/")
}

func (p *Provider) wasSeen(key string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	_, seen := p.seen[key]
	return seen
}

func (p *Provider) markSeen(key string, objectEnd time.Time) {
	p.mu.Lock()
	p.seen[key] = objectEnd
	p.mu.Unlock()
}

func (p *Provider) pruneSeen(now time.Time) {
	p.mu.Lock()
	cutoff := now.Add(-p.retention)
	for key, objectEnd := range p.seen {
		if !objectEnd.After(cutoff) {
			delete(p.seen, key)
		}
	}
	p.mu.Unlock()
}
