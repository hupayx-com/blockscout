defmodule Explorer.Market.History.Source.CryptoCompare do
  @moduledoc """
  Adapter for fetching market history from https://cryptocompare.com.

  The history is fetched for the configured coin. You can specify a
  different coin by changing the targeted coin.

      # In config.exs
      config :explorer, coin: "POA"

  """

  alias Explorer.Market.History.Source
  alias HTTPoison.Response

  @behaviour Source

  @typep unix_timestamp :: non_neg_integer()

  @impl Source
  def fetch_history(previous_days) do
    url = history_url(previous_days)
    headers = [{"Content-Type", "application/json"}]

    case HTTPoison.get(url, headers) do
      {:ok, %Response{body: body, status_code: 200}} ->
        result =
          body
          |> format_data()
          |> reject_zeros()

        {:ok, result}

      _ ->
        :error
    end
  end

  @spec base_url :: String.t()
  defp base_url do
    configured_url = Application.get_env(:explorer, __MODULE__, [])[:base_url]
    configured_url || "https://www.mexc.com"
  end

  @spec date(unix_timestamp()) :: Date.t()
  defp date(unix_timestamp) do
    unix_timestamp
    |> DateTime.from_unix!()
    |> DateTime.to_date()
  end

  @spec format_data(String.t()) :: [Source.record()]
  defp format_data(data) do
    json = Jason.decode!(data)

    for item <- json["data"] do
      itemTuple = List.to_tuple(item)
      %{
        closing_price: Decimal.new(elem(itemTuple, 2)),
        date: date(elem(itemTuple, 0)),
        opening_price: Decimal.new(elem(itemTuple, 1))
      }
    end
  end

  @spec history_url(non_neg_integer()) :: String.t()
  defp history_url(previous_days) do
    query_params = %{
      "symbol" => "HPX_USDT",
      "limit" => previous_days+1,
      "interval" => "1d"
    }

    "#{base_url()}/open/api/v2/market/kline?#{URI.encode_query(query_params)}"
  end

  defp reject_zeros(items) do
    Enum.reject(items, fn item ->
      Decimal.equal?(item.closing_price, 0) && Decimal.equal?(item.opening_price, 0)
    end)
  end
end
