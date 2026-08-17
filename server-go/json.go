package server

import (
	"encoding/json"
)

func jsonMarshalImpl(v any) ([]byte, error) {
	return json.Marshal(v)
}

func jsonUnmarshal(b []byte, v any) error {
	return json.Unmarshal(b, v)
}
