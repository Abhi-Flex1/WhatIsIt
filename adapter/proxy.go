package adapter

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"time"
)

func (a *Adapter) proxyRequest(method, path string, body []byte, headers map[string]string) ([]byte, int, error) {
	url := a.whatsMiau + path
	req, err := http.NewRequest(method, url, bytes.NewReader(body))
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	if a.apiKey != "" {
		req.Header.Set("apikey", a.apiKey)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := a.httpClient.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, resp.StatusCode, err
	}
	return b, resp.StatusCode, nil
}

func (a *Adapter) getInstanceName() string {
	if a.instanceID != "" {
		return a.instanceID
	}
	return "default"
}

func (a *Adapter) instancePath(suffix string) string {
	return fmt.Sprintf("/v1/instance/%s%s", a.getInstanceName(), suffix)
}

func (a *Adapter) messagePath(action string) string {
	return fmt.Sprintf("/v1/instance/%s/message/%s", a.getInstanceName(), action)
}

func (a *Adapter) chatPath(action string) string {
	return fmt.Sprintf("/v1/instance/%s/chat/%s", a.getInstanceName(), action)
}

func (a *Adapter) proxyToWhatsMiau(method, path string, body []byte) ([]byte, int, error) {
	return a.proxyRequest(method, path, body, nil)
}

func (a *Adapter) getHeaders() map[string]string {
	h := map[string]string{}
	if a.apiKey != "" {
		h["apikey"] = a.apiKey
	}
	return h
}
