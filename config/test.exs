use Mix.Config

config :flume,
  name: Flume,
  host: {:system, "FLUME_REDIS_HOST", "127.0.0.1"},
  port: {:system, "FLUME_REDIS_PORT", "6379"},
  namespace: "flume_test",
  database: 0,
  redis_timeout: 5000,
  reconnect_on_sleep: 100,
  poll_timeout: 500,
  pipelines: [
    %{name: "pipeline_1", queue: "default", concurrency: 10},
    %{name: "pipeline_2", queue: "default", concurrency: 10}
  ]
