# Flume

[![pipeline status](https://code.scripbox.io/packages/flume/badges/master/pipeline.svg?style=flat-square)](https://code.scripbox.io/packages/flume/commits/master)
[![coverage report](https://code.scripbox.io/packages/flume/badges/master/coverage.svg?style=flat-square)](https://code.scripbox.io/packages/flume/commits/master)

Flume is a job processing system backed by [GenStage](https://github.com/elixir-lang/gen_stage) & [Redis](https://redis.io/)

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
  - [Pipelines](#pipelines)
  - [Enqueuing Jobs](#enqueueing-jobs)
  - [Creating Workers](#creating-workers)
  - [Scheduled Jobs](#scheduled-jobs)
  - [Rate Limiting](#rate-limiting)
  - [Batch Processing](#batch-processing)
  - [Pipeline Control](#pipeline-control)
  - [Instrumentation](#instrumentation)
- [Testing](#testing)
- [Roadmap](#roadmap)
- [Contributing](#contributing)

## Features

- Store all jobs in Redis for presistence
- Configure the queues in Redis
- Define a supervised producer for each queue in Redis
- Dynamically spawn supervised worker processes for each job
- A producer pulls jobs from Redis via a separate supervised connection module (Redis.Connection)
- Each connection process holds its own connection to Redis
- Each connection process will pop jobs from a specific queue from Redis
- Store each job in a `processing` queue for durability (aka reliable fetching)
- Configure the `min` & `max-demand` for each queue in Redis
- Add `rate-limit` for each queue in Redis
- Ability to process jobs in batches
- Ability to schedule jobs at a particular interval
- Ability to `pause/resume` configured pipelines
- Handle error/exception in Consumer while processing a job
- Retry failed jobs with configurable exponential backoff
- Have a separate configurable logger module

## Requirements

- Elixir 1.6.6+
- Erlang/OTP 21.1+
- Redis 4.0+

## Installation

Add Flume to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:flume, "~> 0.1.0"}
  ]
end
```

Then run `mix deps.get` to install Flume and its dependencies.

## Usage

Add Flume supervisor to your application's supervision tree:

```elixir
defmodule MyApplication.Application do
  use Application

  import Supervisor.Spec

  def start(_type, _args) do
    children = [
      # Start Flume supervisor
      supervisor(Flume, [])
    ]

    opts = [strategy: :one_for_one, name: MyApplication.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

Add `config/flume.exs`:

```elixir
config :flume,
  name: Flume,
  host: "127.0.0.1", # Redis host
  port: "6379", # Redis port
  namespace: "my-app", # Redis keys namespace
  database: 0, # Redis database
  redis_pool_size: 10, # Redis pool size
  redis_timeout: 10_000, # Redis connection timeout
  backoff_initial: 30_000, # Retry backoff intial (30 seconds)
  backoff_max: 36_00_000, # Retry backoff maximum (1 hour)
  max_retries: 15,  # Maximum number of retries
  scheduler_poll_interval: 10_000,  # Scheduled jobs poll interval (10 seconds)
  visibility_timeout: 600, # Time to move jobs from processing queue to retry queue
  dequeue_lock_ttl: 30_000, # ttl of the acquired lock to fetch jobs for bulk pipelines (30 seconds)
  dequeue_process_timeout: 10_000, # process timeout to fetch jobs for bulk pipelines (30 seconds)
  dequeue_lock_poll_interval: 500 # time to poll the queue again if it was locked by another process
```

### Pipelines

Each pipeline is a GenStage pipeline which has these parameters -

* `name` - Name of the pipeline
* `queue` - Name of the Redis queue to pull jobs from
* `max_demand` - Maximum number of jobs to pull from the queue

**Configuration**

```elixir
config :flume,
  pipelines: [
    %{name: "default_pipeline", queue: "default", max_demand: 1000},
  ]
```

Flume supervisor will start these processes:

```asciidoc
                  [Flume.Supervisor]
                         |
                         |
                         |
              [default_pipeline_producer]   <- (Producer)
                         |
                         |
                         |
          [default_pipeline_producer_consumer]   <- (ProducerConsumer)
                         |
                         |
                         |
         [default_pipeline_consumer_supervisor]   <- (ConsumerSupervisor)
                        / \
                       /   \
                      /     \
             [worker_1]     [worker_2]   <- (Worker Processes)
```

### Enqueuing Jobs

Enqueuing jobs into flume requires these things -

* Specify a `queue-name` (like `priority`)
* Specify the worker module (`MyApp.FancyWorker`)
* Specify the worker module's function name (default `:perform`)
* Specify the arguments as per the worker module's function arity

**With default function**

```elixir
Flume.enqueue(:queue_name, MyApp.FancyWorker, [arg_1, arg_2])
```

**With custom function**

```elixir
Flume.enqueue(:queue_name, MyApp.FancyWorker, :myfunc, [arg_1, arg_2])
```

### Creating Workers

Worker modules are responsible for processing a job.
A worker module should define the `function-name` with the exact arity used while queuing the job.

```elixir
defmodule MyApp.FancyWorker do
  def perform(arg_1, arg_2) do
    # your job processing logic
  end
end
```

### Scheduled Jobs

**With default function**

```elixir
# 10 seconds
schedule_time = 10_000

Flume.enqueue_in(:queue_name, schedule_time, MyApp.FancyWorker, [arg_1, arg_2])
```

**With custom function**

```elixir
# 10 seconds
schedule_time = 10_000

Flume.enqueue_in(:queue_name, schedule_time, MyApp.FancyWorker, :myfunc, [arg_1, arg_2])
```

### Rate Limiting

Flume supports rate-limiting for each configured pipeline.

Rate-Limiting has two key parameters -

* `rate_limit_scale` - Time scale in `milliseconds` for the pipeline
* `rate_limit_count` - Total number of jobs to be processed within the time scale

```elixir
rate_limit_count = 1000
rate_limit_scale = 6 * 1000

config :flume,
  pipelines: [
    # This pipeline will process 1000 jobs every 6 seconds
    %{
      name: "limited_pipeline",
      queue: "rate-limit-queue",
      rate_limit_count: rate_limit_count,
      rate_limit_scale: rate_limit_scale,
    }
  ]
```

Flume will process the configured number of jobs (`rate_limit_count`) for each rate-limited pipeline,
even if we are running multiple instances of our application.

### Batch Processing

Flume supports batch-processing for each configured pipeline.
It groups individual jobs by the configured `batch_size` option and
each worker process will receive a group of jobs.


```elixir
config :flume,
  pipelines: [
    # This pipeline will pull (100 * 10) jobs from the queue
    # and group them in batches of 10.
    %{
      name: "batch_pipeline",
      queue: "batch-queue",
      max_demand: 100,
      batch_size: 10
    }
  ]
```

```elixir
defmodule MyApp.BatchWorker do
  def perform(args) do
    # args will be a list of arguments
    # E.g - [[job_1_args], [job_2_args], ...]
    # your job processing logic
  end
end
```

### Pipeline Control

Flume has support to pause/resume each pipeline.
Once a pipeline is paused, the producer process will stop pulling jobs from the queue.
It will process the jobs which are already pulled from the queue.

**Pause a pipeline**

```elixir
# Pause the pipeline temporarily (in memory)
Flume.pause(:default_pipeline)

# Pause the pipeline permanently (in Redis)
Flume.pause(:default_pipeline, true)
```

**Resume a pipeline**

```elixir
# Resume the pipeline temporarily (in memory)
Flume.resume(:default_pipeline)

# Resume the pipeline permanently (in Redis)
Flume.resume(:default_pipeline, true)
```

### Instrumentation

[TODO]

## Testing

Use these guidelines for running tests:

* Disable flume pipelines in test env

**config/test.exs**

```elixir
config :flume,
  pipelines: []
```

*

## Roadmap

* Support multiple queue backends (right now only Redis is supported)

## Contributing

Check formatting (`mix format --check-formatted`)
Run all tests (`mix test`)
