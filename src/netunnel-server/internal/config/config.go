package config

import (
	"errors"
	"flag"
	"os"
	"path/filepath"
	"time"

	"gopkg.in/yaml.v3"
)

const defaultDatabaseURL = "postgresql://ai_ssh_user:ai_ssh_password@127.0.0.1:5432/netunnel"
const defaultListenAddr = ":40061"
const defaultBridgeListenAddr = ":40062"
const defaultSettlementInterval = 1 * time.Minute
const defaultConfigPath = "config.yaml"

type PortRange struct {
	Start int `yaml:"start"`
	End   int `yaml:"end"`
}

type yamlConfig struct {
	DatabaseURL        string      `yaml:"database_url"`
	ListenAddr         string      `yaml:"listen_addr"`
	BridgeListenAddr   string      `yaml:"bridge_listen_addr"`
	SettlementInterval string      `yaml:"settlement_interval"`
	TCPPortRanges      []PortRange `yaml:"tcp_port_ranges"`
	PublicHost         string      `yaml:"public_host"`
	PublicAPIBaseURL   string      `yaml:"public_api_base_url"`
	HostDomainSuffix   string      `yaml:"host_domain_suffix"`
}

type Config struct {
	DatabaseURL        string
	MigrationsDir      string
	ListenAddr         string
	BridgeListenAddr   string
	SettlementInterval time.Duration
	TCPPortRanges      []PortRange
	PublicHost         string
	PublicAPIBaseURL   string
	HostDomainSuffix   string
}

func Load() (Config, error) {
	var cfg Config

	cfg.MigrationsDir = resolveMigrationsDir()
	configPathFlag := flag.String("config", envOrDefault("NETUNNEL_CONFIG", defaultConfigPath), "YAML config file path")
	flag.Parse()

	yamlPath := *configPathFlag
	data, err := os.ReadFile(yamlPath)
	if err != nil {
		if os.IsNotExist(err) {
			return Config{}, errors.New("config file is required: " + yamlPath)
		}
		return Config{}, errors.New("failed to read config file: " + err.Error())
	}

	var yc yamlConfig
	if err := yaml.Unmarshal(data, &yc); err != nil {
		return Config{}, errors.New("failed to parse config file: " + err.Error())
	}

	cfg.DatabaseURL = yc.DatabaseURL
	cfg.ListenAddr = yc.ListenAddr
	cfg.BridgeListenAddr = yc.BridgeListenAddr
	cfg.TCPPortRanges = yc.TCPPortRanges
	cfg.PublicHost = yc.PublicHost
	cfg.PublicAPIBaseURL = yc.PublicAPIBaseURL
	cfg.HostDomainSuffix = yc.HostDomainSuffix

	if yc.SettlementInterval != "" {
		parsed, err := time.ParseDuration(yc.SettlementInterval)
		if err != nil {
			return Config{}, errors.New("invalid settlement_interval: " + err.Error())
		}
		cfg.SettlementInterval = parsed
	}

	if cfg.DatabaseURL == "" {
		return Config{}, errors.New("database url is required")
	}
	if cfg.ListenAddr == "" {
		cfg.ListenAddr = defaultListenAddr
	}
	if cfg.BridgeListenAddr == "" {
		cfg.BridgeListenAddr = defaultBridgeListenAddr
	}
	if cfg.SettlementInterval == 0 {
		cfg.SettlementInterval = defaultSettlementInterval
	}
	if cfg.TCPPortRanges == nil {
		cfg.TCPPortRanges = []PortRange{{Start: 40000, End: 45000}, {Start: 50000, End: 60000}}
	}

	return cfg, nil
}

func resolveMigrationsDir() string {
	candidates := []string{
		filepath.Clean(filepath.Join(".", "sql")),
		filepath.Clean(filepath.Join("..", "..", "sql")),
	}

	for _, candidate := range candidates {
		if stat, err := os.Stat(candidate); err == nil && stat.IsDir() {
			return candidate
		}
	}

	return candidates[0]
}

func envOrDefault(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
