defmodule Explorer.Chain.Import.Runner.InternalTransactions do
  @moduledoc """
  Bulk imports `t:Explorer.Chain.InternalTransactions.t/0`.
  """

  require Ecto.Query

  alias Ecto.{Changeset, Multi, Repo}
  alias Explorer.Chain.{Hash, Import, InternalTransaction, Transaction}
  alias Explorer.Chain.Import.Runner

  import Ecto.Query, only: [from: 2]

  @behaviour Runner

  # milliseconds
  @timeout 60_000

  @type imported :: [
          %{required(:index) => non_neg_integer(), required(:transaction_hash) => Hash.Full.t()}
        ]

  @impl Runner
  def ecto_schema_module, do: InternalTransaction

  @impl Runner
  def option_key, do: :internal_transactions

  @impl Runner
  def imported_table_row do
    %{
      value_type: "[%{index: non_neg_integer(), transaction_hash: Explorer.Chain.Hash.t()}]",
      value_description: "List of maps of the `t:Explorer.Chain.InternalTransaction.t/0` `index` and `transaction_hash`"
    }
  end

  @impl Runner
  def run(multi, changes_list, %{timestamps: timestamps} = options) when is_map(options) do
    insert_options =
      options
      |> Map.get(option_key(), %{})
      |> Map.take(~w(on_conflict timeout)a)
      |> Map.put_new(:timeout, @timeout)
      |> Map.put(:timestamps, timestamps)

    transactions_timeout = options[Runner.Transactions.option_key()][:timeout] || Runner.Transactions.timeout()

    update_transactions_options = %{timeout: transactions_timeout, timestamps: timestamps}

    # Enforce ShareLocks tables order (see docs: sharelocks.md)
    multi
    |> Multi.run(:acquire_transactions, fn repo, _ ->
      acquire_transactions(repo, changes_list)
    end)
    |> Multi.run(:internal_transactions, fn repo, _ ->
      insert(repo, changes_list, insert_options)
    end)
    |> Multi.run(:internal_transactions_indexed_at_transactions, fn repo, %{acquire_transactions: transaction_hashes} ->
      update_transactions(repo, transaction_hashes, update_transactions_options)
    end)
  end

  @impl Runner
  def timeout, do: @timeout

  @spec insert(Repo.t(), [map], %{
          optional(:on_conflict) => Runner.on_conflict(),
          required(:timeout) => timeout,
          required(:timestamps) => Import.timestamps()
        }) ::
          {:ok, [%{index: non_neg_integer, transaction_hash: Hash.t()}]}
          | {:error, [Changeset.t()]}
  defp insert(repo, changes_list, %{timeout: timeout, timestamps: timestamps} = options)
       when is_list(changes_list) do
    on_conflict = Map.get_lazy(options, :on_conflict, &default_on_conflict/0)

    # Enforce InternalTransaction ShareLocks order (see docs: sharelocks.md)
    ordered_changes_list = Enum.sort_by(changes_list, &{&1.transaction_hash, &1.index})

    final_changes_list = reject_pending_transactions(ordered_changes_list, repo)

    {:ok, internal_transactions} =
      Import.insert_changes_list(
        repo,
        final_changes_list,
        conflict_target: [:transaction_hash, :index],
        for: InternalTransaction,
        on_conflict: on_conflict,
        returning: [:transaction_hash, :index],
        timeout: timeout,
        timestamps: timestamps
      )

    {:ok,
     for(
       internal_transaction <- internal_transactions,
       do: Map.take(internal_transaction, [:id, :index, :transaction_hash])
     )}
  end

  defp default_on_conflict do
    from(
      internal_transaction in InternalTransaction,
      update: [
        set: [
          block_number: fragment("EXCLUDED.block_number"),
          call_type: fragment("EXCLUDED.call_type"),
          created_contract_address_hash: fragment("EXCLUDED.created_contract_address_hash"),
          created_contract_code: fragment("EXCLUDED.created_contract_code"),
          error: fragment("EXCLUDED.error"),
          from_address_hash: fragment("EXCLUDED.from_address_hash"),
          gas: fragment("EXCLUDED.gas"),
          gas_currency_hash: fragment("EXCLUDED.gas_currency_hash"),
          gas_fee_recipient_hash: fragment("EXCLUDED.gas_fee_recipient_hash"),
          gas_used: fragment("EXCLUDED.gas_used"),
          # Don't update `index` as it is part of the composite primary key and used for the conflict target
          init: fragment("EXCLUDED.init"),
          input: fragment("EXCLUDED.input"),
          output: fragment("EXCLUDED.output"),
          to_address_hash: fragment("EXCLUDED.to_address_hash"),
          trace_address: fragment("EXCLUDED.trace_address"),
          # Don't update `transaction_hash` as it is part of the composite primary key and used for the conflict target
          transaction_index: fragment("EXCLUDED.transaction_index"),
          type: fragment("EXCLUDED.type"),
          value: fragment("EXCLUDED.value"),
          inserted_at: fragment("LEAST(?, EXCLUDED.inserted_at)", internal_transaction.inserted_at),
          updated_at: fragment("GREATEST(?, EXCLUDED.updated_at)", internal_transaction.updated_at)
        ]
      ],
      # `IS DISTINCT FROM` is used because it allows `NULL` to be equal to itself
      where:
        fragment(
          "(EXCLUDED.call_type, EXCLUDED.created_contract_address_hash, EXCLUDED.created_contract_code, EXCLUDED.error, EXCLUDED.from_address_hash, EXCLUDED.gas, EXCLUDED.gas_currency_hash, EXCLUDED.gas_fee_recipient_hash, EXCLUDED.gas_used, EXCLUDED.init, EXCLUDED.input, EXCLUDED.output, EXCLUDED.to_address_hash, EXCLUDED.trace_address, EXCLUDED.transaction_index, EXCLUDED.type, EXCLUDED.value) IS DISTINCT FROM (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          internal_transaction.call_type,
          internal_transaction.created_contract_address_hash,
          internal_transaction.created_contract_code,
          internal_transaction.error,
          internal_transaction.from_address_hash,
          internal_transaction.gas,
          internal_transaction.gas_currency_hash,
          internal_transaction.gas_fee_recipient_hash,
          internal_transaction.gas_used,
          internal_transaction.init,
          internal_transaction.input,
          internal_transaction.output,
          internal_transaction.to_address_hash,
          internal_transaction.trace_address,
          internal_transaction.transaction_index,
          internal_transaction.type,
          internal_transaction.value
        )
    )
  end

  defp acquire_transactions(repo, internal_transactions) do
    transaction_hashes =
      internal_transactions
      |> MapSet.new(& &1.transaction_hash)
      |> MapSet.to_list()

    query =
      from(
        t in Transaction,
        where: t.hash in ^transaction_hashes,
        where: not is_nil(t.block_hash),
        select: t.hash,
        # Enforce Transaction ShareLocks order (see docs: sharelocks.md)
        order_by: t.hash,
        lock: "FOR UPDATE"
      )

    hashes = repo.all(query)

    {:ok, hashes}
  end

  defp update_transactions(repo, transaction_hashes, %{
         timeout: timeout,
         timestamps: timestamps
       })
       when is_list(transaction_hashes) do
    update_query =
      from(
        t in Transaction,
        where: t.hash in ^transaction_hashes,
        # ShareLocks order already enforced by `acquire_transactions` (see docs: sharelocks.md)
        update: [
          set: [
            internal_transactions_indexed_at: ^timestamps.updated_at,
            created_contract_address_hash:
              fragment(
                "(SELECT it.created_contract_address_hash FROM internal_transactions AS it WHERE it.transaction_hash = ? ORDER BY it.index ASC LIMIT 1)",
                t.hash
              ),
            error:
              fragment(
                "(SELECT it.error FROM internal_transactions AS it WHERE it.transaction_hash = ? ORDER BY it.index ASC LIMIT 1)",
                t.hash
              ),
            status:
              fragment(
                "CASE WHEN (SELECT it.error FROM internal_transactions AS it WHERE it.transaction_hash = ? ORDER BY it.index ASC LIMIT 1) IS NULL THEN ? ELSE ? END",
                t.hash,
                type(^:ok, t.status),
                type(^:error, t.status)
              )
          ]
        ]
      )

    try do
      {_transaction_count, result} = repo.update_all(update_query, [], timeout: timeout)

      {:ok, result}
    rescue
      postgrex_error in Postgrex.Error ->
        {:error, %{exception: postgrex_error, transaction_hashes: transaction_hashes}}
    end
  end

  defp reject_pending_transactions(ordered_changes_list, repo) do
    transaction_hashes =
      ordered_changes_list
      |> Enum.map(& &1.transaction_hash)
      |> Enum.dedup()

    query =
      from(t in Transaction,
        where: t.hash in ^transaction_hashes,
        where: is_nil(t.block_hash),
        select: t.hash
      )

    pending_transactions = repo.all(query)

    ordered_changes_list
    |> Enum.reject(fn %{transaction_hash: hash} -> Enum.member?(pending_transactions, hash) end)
  end
end
