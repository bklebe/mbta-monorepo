defmodule Concentrate.MergeFilter do
  @moduledoc """
  ProducerConsumer which merges the data given to it, filters, and outputs the result.

  We manage the demand from producers manually.
  * On subscription, we ask for 1 event
  * Once we've received an event, schedule a timeout for 1s
  * When the timeout happens, merge and filter the current state
  * Request new events from producers who were part of the last merge
  """
  use GenStage
  require Logger
  alias Concentrate.Merge.Table
  alias Concentrate.{Filter, TripUpdate, VehiclePosition, StopTimeUpdate}
  @start_link_opts [:name]

  defstruct timeout: 1_000,
            timer: nil,
            table: Table.new(),
            demand: %{},
            filters: []

  def start_link(opts \\ []) do
    start_link_opts = Keyword.take(opts, @start_link_opts)
    opts = Keyword.drop(opts, @start_link_opts)
    GenStage.start_link(__MODULE__, opts, start_link_opts)
  end

  @impl GenStage
  def init(opts) do
    filters = Keyword.get(opts, :filters, [])
    state = %__MODULE__{filters: filters}

    state =
      case Keyword.fetch(opts, :timeout) do
        {:ok, timeout} -> %{state | timeout: timeout}
        _ -> state
      end

    opts = Keyword.take(opts, [:subscribe_to, :dispatcher])
    opts = Keyword.put_new(opts, :dispatcher, GenStage.BroadcastDispatcher)
    {:producer_consumer, state, opts}
  end

  @impl GenStage
  def handle_subscribe(:producer, _options, from, state) do
    state = %{state | table: Table.add(state.table, from), demand: Map.put(state.demand, from, 1)}
    :ok = GenStage.ask(from, 1)
    {:manual, state}
  end

  def handle_subscribe(_, _, _, state) do
    {:automatic, state}
  end

  @impl GenStage
  def handle_cancel(_reason, from, state) do
    state = %{
      state
      | table: Table.remove(state.table, from),
        demand: Map.delete(state.demand, from)
    }

    {:noreply, [], state}
  end

  @impl GenStage
  def handle_events(events, from, state) do
    latest_data = List.last(events)

    state = %{
      state
      | table: Table.update(state.table, from, latest_data),
        demand: Map.update!(state.demand, from, fn demand -> demand - length(events) end)
    }

    state =
      if state.timer do
        state
      else
        %{state | timer: Process.send_after(self(), :timeout, state.timeout)}
      end

    {:noreply, [], state}
  end

  @impl GenStage
  def handle_info(:timeout, state) do
    {time, merged} = :timer.tc(&Table.items/1, [state.table])

    Logger.debug(fn ->
      "#{__MODULE__} merge time=#{time / 1_000}"
    end)

    {time, sorted} = :timer.tc(&Enum.sort_by/2, [merged, &sort_key/1])

    Logger.debug(fn ->
      "#{__MODULE__} sort time=#{time / 1_000}"
    end)

    {time, filtered} = :timer.tc(&Filter.run/2, [sorted, state.filters])

    Logger.debug(fn ->
      "#{__MODULE__} filter time=#{time / 1_000}"
    end)

    state = %{state | timer: nil, demand: ask_demand(state.demand)}
    {:noreply, [filtered], state}
  end

  def handle_info(msg, state) do
    Logger.warn(fn ->
      "unknown message to #{__MODULE__} #{inspect(self())}: #{inspect(msg)}"
    end)

    {:noreply, [], state}
  end

  defp ask_demand(demand_map) do
    for {from, demand} <- demand_map, into: %{} do
      if demand == 0 do
        GenStage.ask(from, 1)
        {from, 1}
      else
        {from, demand}
      end
    end
  end

  defp sort_key(%TripUpdate{}), do: 0
  defp sort_key(%VehiclePosition{}), do: 1
  defp sort_key(%StopTimeUpdate{}), do: 2
  defp sort_key(_), do: 4
end
