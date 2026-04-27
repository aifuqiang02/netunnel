package main

import (
	"context"
	"errors"
	"io"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"netunnel/server/internal/app"
	"netunnel/server/internal/config"
)

func main() {
	logFile, err := setupFileLogging()
	if err != nil {
		log.Printf("setup file logging: %v", err)
	} else {
		defer logFile.Close()
	}

	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	application, err := app.Bootstrap(ctx, cfg)
	if err != nil {
		log.Fatalf("bootstrap app: %v", err)
	}
	defer func() {
		if closeErr := application.Close(); closeErr != nil {
			log.Printf("close app: %v", closeErr)
		}
	}()

	if err := application.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
		log.Fatalf("run app: %v", err)
	}
}

func setupFileLogging() (*os.File, error) {
	logPath := filepath.Join("logs", "server.log")
	if err := os.MkdirAll(filepath.Dir(logPath), 0755); err != nil {
		return nil, err
	}

	file, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		return nil, err
	}
	log.SetOutput(io.MultiWriter(os.Stderr, file))
	log.Printf("file logging enabled: path=%s", logPath)
	return file, nil
}
