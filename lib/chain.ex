# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chain do
  alias Chain.BlockCache, as: Block
  alias Chain.Transaction
  alias Model.ChainSql
  use GenServer
  defstruct peak: nil, by_hash: %{}, states: %{}

  @type t :: %Chain{
          peak: Chain.Block.t(),
          by_hash: %{binary() => Chain.Block.t()} | nil,
          states: Map.t()
        }

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(ets_extra) do
    case GenServer.start_link(__MODULE__, ets_extra, name: __MODULE__, hibernate_after: 5_000) do
      {:ok, pid} ->
        Chain.BlockCache.warmup()
        Diode.puts("====== Chain    ======")
        peak = peak_block()
        Diode.puts("Peak  Block: #{Block.printable(peak)}")
        Diode.puts("Final Block: #{Block.printable(Block.last_final(peak))}")
        Diode.puts("")

        {:ok, pid}

      error ->
        error
    end
  end

  @spec init(any()) :: {:ok, Chain.t()}
  def init(ets_extra) do
    ProcessLru.new(:blocks, 10)
    EtsLru.new(Chain.Lru, 1000)

    _create(ets_extra)
    state = load_blocks()

    {:ok, state}
  end

  def window_size() do
    100
  end

  def genesis_hash() do
    Block.hash(block(0))
  end

  def sync() do
    call(fn state, _from -> {:reply, :ok, state} end)
  end

  @doc "Function for unit tests, replaces the current state"
  def set_state(state) do
    call(fn _state, _from ->
      {:reply, :ok, seed(state)}
    end)

    Chain.Worker.update_sync()
    :ok
  end

  @doc "Function for unit tests, resets state to genesis state"
  def reset_state() do
    set_state(genesis_state())
    Chain.BlockCache.reset()
  end

  def state() do
    state = call(fn state, _from -> {:reply, state, state} end)

    by_hash =
      Enum.map(blocks(Block.hash(state.peak)), fn block ->
        {Block.hash(block), Block.with_state(block)}
      end)
      |> Map.new()

    %{state | by_hash: by_hash}
  end

  defp call(fun, timeout \\ 25000) do
    GenServer.call(__MODULE__, {:call, fun}, timeout)
  end

  @doc "Gaslimit for block validation and estimation"
  def gas_limit() do
    20_000_000
  end

  @doc "GasPrice for block validation and estimation"
  def gas_price() do
    0
  end

  @spec average_transaction_gas() :: 200_000
  def average_transaction_gas() do
    200_000
  end

  def blocktime_goal() do
    15
  end

  @spec peak() :: integer()
  def peak() do
    Block.number(peak_block())
  end

  def set_peak(%Chain.Block{} = block) do
    call(
      fn state, _from ->
        ChainSql.put_peak(block)
        ets_prefetch()
        {:reply, :ok, %{state | peak: block}}
      end,
      :infinity
    )
  end

  def epoch() do
    case :persistent_term.get(:epoch, nil) do
      nil -> Block.epoch(peak_block())
      num -> num
    end
  end

  def epoch_length() do
    if Diode.dev_mode?() do
      4
    else
      40320
    end
  end

  @spec final_block() :: Chain.Block.t()
  def final_block() do
    call(fn state, _from -> {:reply, Block.last_final(state.peak), state} end)
  end

  @spec peak_block() :: Chain.Block.t()
  def peak_block() do
    call(fn state, _from -> {:reply, state.peak, state} end)
  end

  @spec peak_state() :: Chain.State.t()
  def peak_state() do
    Block.state(peak_block())
  end

  @spec block(number()) :: Chain.Block.t() | nil
  def block(n) do
    ets_lookup_idx(n, fn -> ChainSql.block(n) end)
  end

  @spec blockhash(number()) :: binary() | nil
  def blockhash(n) do
    ets_lookup_hash(n)
  end

  @doc """
    Checks for existance of the given block. This is faster
    than using block_by_hash() as it can be fullfilled with
    a single ets lookoup and no need to ever fetch the full
    block.
  """
  @spec block_by_hash?(any()) :: boolean()
  def block_by_hash?(nil) do
    false
  end

  def block_by_hash?(hash) do
    case ets_lookup(hash, fn -> true end) do
      nil -> false
      true -> true
      %Chain.Block{} -> true
    end
  end

  @spec block_by_hash(any()) :: Chain.Block.t() | nil
  def block_by_hash(nil) do
    nil
  end

  def block_by_hash(hash) do
    # :erlang.system_flag(:backtrace_depth, 3)
    # {:current_stacktrace, what} = :erlang.process_info(self(), :current_stacktrace)
    # :io.format("block_by_hash: ~p~n", [what])

    Stats.tc(:block_by_hash, fn ->
      do_block_by_hash(hash)
    end)
  end

  defp do_block_by_hash(hash) do
    ProcessLru.fetch(:blocks, hash, fn ->
      ets_lookup(hash, fn ->
        Stats.tc(:sql_block_by_hash, fn ->
          EtsLru.fetch(Chain.Lru, hash, fn ->
            ChainSql.block_by_hash(hash)
          end)
        end)
      end)
    end)
  end

  def block_by_txhash(txhash) do
    ChainSql.block_by_txhash(txhash)
  end

  def transaction(txhash) do
    ChainSql.transaction(txhash)
  end

  # returns all blocks from the current peak
  @spec blocks() :: Enumerable.t()
  def blocks() do
    blocks(Block.hash(peak_block()))
  end

  # returns all blocks from the given hash
  @spec blocks(Chain.Block.t() | binary()) :: Enumerable.t()
  def blocks(block_or_hash) do
    Stream.unfold([block_or_hash], fn
      [] ->
        nil

      [hash] when is_binary(hash) ->
        case ChainSql.blocks_by_hash(hash, 100) do
          [] -> nil
          [block | rest] -> {block, rest}
        end

      [block] ->
        case ChainSql.blocks_by_hash(Block.hash(block), 100) do
          [] -> nil
          [block | rest] -> {block, rest}
        end

      [block | rest] ->
        {block, rest}
    end)
  end

  @spec load_blocks() :: Chain.t()
  defp load_blocks() do
    case ChainSql.peak_block() do
      nil ->
        genesis_state() |> seed()

      block ->
        ets_prefetch()
        %Chain{peak: block, by_hash: nil}
    end
  end

  defp seed(state) do
    ChainSql.truncate_blocks()

    Map.values(state.by_hash)
    |> Enum.each(fn block ->
      ChainSql.put_block(block)
    end)

    ets_prefetch()
    peak = ChainSql.peak_block()
    :persistent_term.put(:epoch, Block.epoch(peak))
    %Chain{peak: peak, by_hash: nil}
  end

  defp genesis_state() do
    {gen, parent} = genesis()
    hash = Block.hash(gen)
    phash = Block.hash(parent)

    %Chain{
      peak: gen,
      by_hash: %{hash => gen, phash => parent},
      states: %{}
    }
  end

  @spec add_block(any()) :: :added | :stored
  def add_block(block, relay \\ true, async \\ false) do
    block_hash = Block.hash(block)
    true = Block.has_state?(block)

    cond do
      block_by_hash?(block_hash) ->
        IO.puts("Chain.add_block: Skipping existing block (2)")
        :added

      Block.number(block) < 1 ->
        IO.puts("Chain.add_block: Rejected invalid genesis block")
        :rejected

      true ->
        parent_hash = Block.parent_hash(block)

        if async == false do
          ret = GenServer.call(__MODULE__, {:add_block, block, parent_hash, relay})

          if ret == :added do
            Chain.Worker.update()
          end

          ret
        else
          GenServer.cast(__MODULE__, {:add_block, block, parent_hash, relay})
          :unknown
        end
    end
  end

  def handle_cast({:add_block, block, parent_hash, relay}, state) do
    {:reply, _reply, state} = handle_call({:add_block, block, parent_hash, relay}, nil, state)
    {:noreply, state}
  end

  def handle_call({:add_block, block, parent_hash, relay}, _from, state) do
    Stats.tc(:addblock, fn ->
      peak = state.peak
      peak_hash = Block.hash(peak)
      info = Block.printable(block)

      cond do
        block_by_hash?(Block.hash(block)) ->
          IO.puts("Chain.add_block: Skipping existing block (3)")
          {:reply, :added, state}

        peak_hash != parent_hash and Block.total_difficulty(block) <= Block.total_difficulty(peak) ->
          ChainSql.put_new_block(block)
          ets_add_alt(block)
          IO.puts("Chain.add_block: Extended   alt #{info} | (@#{Block.printable(peak)}")
          {:reply, :stored, state}

        true ->
          # Update the state
          if peak_hash == parent_hash do
            IO.puts("Chain.add_block: Extending main #{info}")

            Stats.incr(:block_cnt)
            ChainSql.put_block(block)
            ets_add(block)
          else
            IO.puts("Chain.add_block: Replacing main #{info}")

            # Recursively makes a new branch normative
            ChainSql.put_peak(block)
            ets_refetch(block)
          end

          state = %{state | peak: block}
          :persistent_term.put(:epoch, Block.epoch(block))

          # Printing some debug output per transaction
          if Diode.dev_mode?() do
            print_transactions(block)
          end

          # Remove all transactions that have been processed in this block
          # from the outstanding local transaction pool
          Chain.Pool.remove_transactions(block)

          # Let the ticketstore know the new block
          PubSub.publish(:rpc, {:rpc, :block, block})

          Debouncer.immediate(TicketStore, fn ->
            TicketStore.newblock(block)
          end)

          if relay do
            if Wallet.equal?(Block.miner(block), Diode.miner()) do
              Kademlia.broadcast(Block.export(block))
            else
              Kademlia.relay(Block.export(block))
            end
          end

          {:reply, :added, state}
      end
    end)
  end

  def handle_call({:call, fun}, from, state) when is_function(fun) do
    fun.(state, from)
  end

  def export_blocks(filename \\ "block_export.sq3", blocks \\ Chain.blocks()) do
    Sqlitex.with_db(filename, fn db ->
      Sqlitex.query!(db, """
      CREATE TABLE IF NOT EXISTS block_export (
        number INTEGER PRIMARY KEY,
        data BLOB
      ) WITHOUT ROWID;
      """)

      start =
        case Sqlitex.query!(db, "SELECT MAX(number) as max FROM block_export") do
          [[max: nil]] -> 0
          [[max: max]] -> max
        end

      IO.puts("start: #{start}")

      Stream.take_while(blocks, fn block -> Block.number(block) > start end)
      |> Stream.chunk_every(100)
      |> Task.async_stream(fn blocks ->
        IO.puts("Writing block #{Block.number(hd(blocks))}")

        Enum.map(blocks, fn block ->
          data =
            Block.export(block)
            |> BertInt.encode!()

          [Block.number(block), data]
        end)
      end)
      |> Stream.each(fn {:ok, blocks} ->
        :ok = Sqlitex.exec(db, "BEGIN")

        Enum.each(blocks, fn [num, data] ->
          Sqlitex.query!(
            db,
            "INSERT INTO block_export (number, data) VALUES(?1, CAST(?2 AS BLOB))",
            bind: [num, data]
          )
        end)

        :ok = Sqlitex.exec(db, "COMMIT")
      end)
      |> Stream.run()
    end)
  end

  defp decode_blocks("") do
    []
  end

  defp decode_blocks(<<size::unsigned-size(32), block::binary-size(size), rest::binary>>) do
    [BertInt.decode!(block)] ++ decode_blocks(rest)
  end

  def import_blocks(filename) when is_binary(filename) do
    File.read!(filename)
    |> decode_blocks()
    |> import_blocks()
  end

  def import_blocks(blocks) do
    Stream.drop_while(blocks, fn block ->
      block_by_hash?(Block.hash(block))
    end)
    |> do_import_blocks()
  end

  defp do_import_blocks(blocks) do
    ProcessLru.new(:blocks, 10)
    prev = Enum.at(blocks, 0) |> Block.parent()

    # replay block backup list
    lastblock =
      Enum.reduce_while(blocks, prev, fn nextblock, prevblock ->
        if prevblock != nil do
          ProcessLru.put(:blocks, Block.hash(prevblock), prevblock)
        end

        block_hash = Block.hash(nextblock)

        case block_by_hash(block_hash) do
          %Chain.Block{} = existing ->
            {:cont, existing}

          nil ->
            ret =
              Stats.tc(:vldt, fn ->
                Block.validate(nextblock, prevblock)
              end)

            case ret do
              %Chain.Block{} = block ->
                add_block(block, false, false)
                {:cont, block}

              nonblock ->
                :io.format("Chain.import_blocks(2): Failed with ~p on: ~p~n", [
                  nonblock,
                  Block.printable(nextblock)
                ])

                {:halt, nonblock}
            end
        end
      end)

    finish_sync()
    lastblock
  end

  def is_active_sync(register \\ false) do
    me = self()

    case Process.whereis(:active_sync) do
      nil ->
        if register do
          Process.register(self(), :active_sync)
          PubSub.publish(:rpc, {:rpc, :syncing, true})
        end

        true

      ^me ->
        true

      _other ->
        false
    end
  end

  def throttle_sync(register \\ false, msg \\ "Syncing") do
    # For better resource usage we only let one process sync at full
    # throttle

    if is_active_sync(register) do
      :io.format("#{msg} ...~n")
    else
      :io.format("#{msg} (background worker) ...~n")
      Process.sleep(30_000)
    end
  end

  defp finish_sync() do
    Process.unregister(:active_sync)
    PubSub.publish(:rpc, {:rpc, :syncing, false})

    spawn(fn ->
      Model.SyncSql.clean_before(Chain.peak())
      Model.SyncSql.free_space()
    end)
  end

  def print_transactions(block) do
    for {tx, rcpt} <- Enum.zip([Block.transactions(block), Block.receipts(block)]) do
      status =
        case rcpt.msg do
          :evmc_revert -> ABI.decode_revert(rcpt.evmout)
          _ -> {rcpt.msg, rcpt.evmout}
        end

      Transaction.print(tx)
      IO.puts("\tStatus:      #{inspect(status)}")
    end

    IO.puts("")
  end

  @spec state(number()) :: Chain.State.t()
  def state(n) do
    Block.state(block(n))
  end

  def store_file(filename, term, overwrite \\ false) do
    if overwrite or not File.exists?(filename) do
      content = BertInt.encode!(term)

      with :ok <- File.mkdir_p(Path.dirname(filename)) do
        tmp = "#{filename}.#{:erlang.phash2(self())}"
        File.write!(tmp, content)
        File.rename!(tmp, filename)
      end
    end

    term
  end

  def load_file(filename, default \\ nil) do
    case File.read(filename) do
      {:ok, content} ->
        BertInt.decode_unsafe!(content)

      {:error, _} ->
        case default do
          fun when is_function(fun) -> fun.()
          _ -> default
        end
    end
  end

  defp genesis() do
    {Chain.GenesisFactory.testnet(), Chain.GenesisFactory.testnet_parent()}
  end

  #######################
  # ETS CACHE FUNCTIONS
  #######################
  @ets_size 1000
  defp ets_prefetch() do
    :persistent_term.put(:placeholder_complete, false)
    _clear()

    Diode.start_subwork("clearing alt blocks", fn ->
      ChainSql.clear_alt_blocks()
      # for block <- ChainSql.alt_blocks(), do: ets_add_alt(block)
    end)

    Diode.start_subwork("preloading hashes", fn ->
      for [hash: hash, number: number] <- ChainSql.all_block_hashes() do
        ets_add_placeholder(hash, number)
      end

      :persistent_term.put(:placeholder_complete, true)
    end)

    Diode.start_subwork("preloading top blocks", fn ->
      for block <- ChainSql.top_blocks(@ets_size), do: ets_add(block)
    end)
  end

  # Just fetching blocks of a newly adopted chain branch
  defp ets_refetch(nil) do
    :ok
  end

  defp ets_refetch(block) do
    block_hash = Block.hash(block)
    idx = Block.number(block)

    case do_ets_lookup(idx) do
      [{^idx, ^block_hash}] ->
        :ok

      _other ->
        ets_add(block)

        Block.parent_hash(block)
        |> ChainSql.block_by_hash()
        |> ets_refetch()
    end
  end

  defp ets_add_alt(block) do
    # block = Block.strip_state(block)
    _insert(Block.hash(block), true)
  end

  defp ets_add_placeholder(hash, number) do
    _insert(hash, true)
    _insert(number, hash)
  end

  defp placeholder_complete() do
    :persistent_term.get(:placeholder_complete, false)
  end

  defp ets_add(block) do
    _insert(Block.hash(block), block)
    _insert(Block.number(block), Block.hash(block))
    ets_remove_idx(Block.number(block) - @ets_size)
  end

  defp ets_remove_idx(idx) when idx <= 0 do
    :ok
  end

  defp ets_remove_idx(idx) do
    case do_ets_lookup(idx) do
      [{^idx, block_hash}] ->
        _insert(block_hash, true)

      _ ->
        nil
    end
  end

  defp ets_lookup_idx(idx, default) when is_integer(idx) do
    case do_ets_lookup(idx) do
      [] -> default.()
      [{^idx, block_hash}] -> block_by_hash(block_hash)
    end
  end

  defp ets_lookup_hash(idx) when is_integer(idx) do
    case do_ets_lookup(idx) do
      [] -> nil
      [{^idx, block_hash}] -> block_hash
    end
  end

  defp ets_lookup(hash, default) when is_binary(hash) do
    case do_ets_lookup(hash) do
      [] -> if placeholder_complete(), do: nil, else: default.()
      [{^hash, true}] -> default.()
      [{^hash, block}] -> block
    end
  end

  defp do_ets_lookup(idx) do
    _lookup(idx)
    # Regularly getting output like this from the code below:
    # Slow ets lookup 16896
    # Slow ets lookup 10506

    # {time, ret} = :timer.tc(fn -> _lookup(idx) end)

    # if time > 10000 do
    #   :io.format("Slow ets lookup ~p~n", [time])
    # end

    # ret
  end

  defp _create(ets_extra) do
    __MODULE__ =
      :ets.new(__MODULE__, [:named_table, :public, {:read_concurrency, true}] ++ ets_extra)
  end

  defp _lookup(idx), do: :ets.lookup(__MODULE__, idx)
  defp _insert(key, value), do: :ets.insert(__MODULE__, {key, value})
  defp _clear(), do: :ets.delete_all_objects(__MODULE__)
end
