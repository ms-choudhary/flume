defmodule Flume.Queue do
  @doc false
  defmacro __using__(_) do
    quote location: :keep do
      alias Exq.Support.Config

      def enqueue(queue, worker, args) do
        GenServer.call(Flume.Queue.Server, {:enqueue, queue, worker, args})
      end

      def dequeue(queue, job) do
        GenServer.call(Flume.Queue.Server, {:dequeue, queue, job})
      end

      def fetch_jobs(queue, count) do
        GenServer.call(Flume.Queue.Server, {:fetch_jobs, queue, count})
      end
    end
  end
end
