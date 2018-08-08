defprotocol Membrane.Payload do
  @moduledoc """
  This protocol describes actions common to all payload types.

  The most basic payload type is simply a binary for which `#{__MODULE__}`
  is implemented by the Membrane Core.
  """

  @type t :: any()

  @doc """
  Returns total size of payload in bytes
  """
  @spec size(payload :: t()) :: non_neg_integer()
  def size(payload)

  @doc """
  Splits the payload at given position (1st part has the size equal to `at_pos` argument)

  `at_pos` has to be greater than 0 and smaller than the size of payload. This guarantees
  returned payloads are never empty.

  When such conditions are not met, the function should raise.
  """
  @spec split_at!(payload :: t(), at_pos :: pos_integer()) :: {t(), t()}
  def split_at!(payload, at_pos)

  @doc """
  Converts payload into binary
  """
  @spec to_binary(t()) :: binary()
  def to_binary(payload)

  @doc """
  Returns an atom describing type of the payload.
  """
  @spec type(t()) :: atom()
  def type(payload)
end

defimpl Membrane.Payload, for: BitString do
  @spec size(payload :: binary()) :: pos_integer
  def size(data) when is_binary(data) do
    data |> byte_size()
  end

  @spec split_at!(binary(), pos_integer) :: {binary(), binary()}
  def split_at!(data, at_pos) when 0 < at_pos and at_pos < byte_size(data) do
    <<part1::binary-size(at_pos), part2::binary>> = data
    {part1, part2}
  end

  @spec to_binary(binary()) :: binary()
  def to_binary(data) when is_binary(data) do
    data
  end

  @spec type(binary()) :: :binary
  def type(_), do: :binary
end
