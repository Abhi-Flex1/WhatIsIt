package adapter

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

type WSClient struct {
	conn *websocket.Conn
	send chan []byte
}

type WSHub struct {
	mu      sync.Mutex
	clients map[*WSClient]struct{}
}

func NewWSHub() *WSHub {
	return &WSHub{clients: make(map[*WSClient]struct{})}
}

func (h *WSHub) Add(c *websocket.Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	client := &WSClient{conn: c, send: make(chan []byte, 256)}
	h.clients[client] = struct{}{}
	go client.writePump()
	go client.readPump()
}

func (h *WSHub) Remove(c *websocket.Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for client := range h.clients {
		if client.conn == c {
			close(client.send)
			delete(h.clients, client)
			break
		}
	}
}

func (h *WSHub) Broadcast(event BackendEvent) {
	b, _ := json.Marshal(event)
	h.mu.Lock()
	defer h.mu.Unlock()
	for client := range h.clients {
		select {
		case client.send <- b:
		default:
			close(client.send)
			delete(h.clients, client)
		}
	}
}

func (c *WSClient) readPump() {
	defer c.conn.Close()
	for {
		if _, _, err := c.conn.ReadMessage(); err != nil {
			break
		}
	}
}

func (c *WSClient) writePump() {
	defer c.conn.Close()
	for msg := range c.send {
		if err := c.conn.WriteMessage(websocket.TextMessage, msg); err != nil {
			break
		}
	}
}

func (h *WSHub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	c, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Println("ws upgrade:", err)
		return
	}
	h.Add(c)
}
