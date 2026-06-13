package main

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"strconv"
	"time"

	"github.com/segmentio/kafka-go"
)

type kafkaPublisher struct {
	enabled bool
	writer  *kafka.Writer
	topic   string
	ch      chan kafka.Message
	done    chan struct{}
}

func newKafkaPublisher() *kafkaPublisher {
	enabled, _ := strconv.ParseBool(os.Getenv("KAFKA_ENABLED"))
	if !enabled {
		log.Printf("kafka publisher disabled (KAFKA_ENABLED=false)")
		return &kafkaPublisher{enabled: false}
	}
	brokers := getenv("KAFKA_BROKERS", "kafka.data-streaming.svc.cluster.local:9092")
	topic := getenv("KAFKA_TOPIC", "raw-events")
	w := &kafka.Writer{
		Addr:                   kafka.TCP(brokers),
		Topic:                  topic,
		Balancer:               &kafka.Hash{},
		RequiredAcks:           kafka.RequireOne,
		AllowAutoTopicCreation: false,
		Async:                  true,
		BatchTimeout:           100 * time.Millisecond,
		Completion: func(messages []kafka.Message, err error) {
			if err != nil {
				log.Printf("kafka async publish error: %v (n=%d)", err, len(messages))
			}
		},
	}
	p := &kafkaPublisher{
		enabled: true,
		writer:  w,
		topic:   topic,
		ch:      make(chan kafka.Message, 1024),
		done:    make(chan struct{}),
	}
	go p.run()
	log.Printf("kafka publisher enabled brokers=%s topic=%s", brokers, topic)
	return p
}

func (p *kafkaPublisher) run() {
	defer close(p.done)
	for msg := range p.ch {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		if err := p.writer.WriteMessages(ctx, msg); err != nil {
			log.Printf("kafka write error: %v", err)
		}
		cancel()
	}
}

func (p *kafkaPublisher) publish(key string, payload any) {
	if !p.enabled {
		return
	}
	body, err := json.Marshal(payload)
	if err != nil {
		log.Printf("kafka marshal error: %v", err)
		return
	}
	select {
	case p.ch <- kafka.Message{Key: []byte(key), Value: body, Time: time.Now().UTC()}:
	default:
		log.Printf("kafka channel full, dropping event key=%s", key)
	}
}

func (p *kafkaPublisher) close() {
	if !p.enabled {
		return
	}
	close(p.ch)
	<-p.done
	_ = p.writer.Close()
}

func getenv(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
