defmodule Membrane.Element.Base.Sink do
  @moduledoc """
  This module should be used by all elements that are sources.
  """


  @doc """
  Callback that is called when buffer arrives.

  The arguments are:

  - caps
  - data
  - current element state

  While implementing these callbacks, please use pattern matching to define
  what caps are supported. In other words, define one function matching this
  signature per each caps supported.
  """
  @callback handle_buffer(%Membrane.Caps{}, bitstring, any) ::
    {:ok, any} |
    {:error, any}


  defmacro __using__(_) do
    quote do
      @behaviour Membrane.Element.Base.Sink

      use Membrane.Element.Base.Mixin.Process


      @doc """
      Callback invoked on incoming buffer.

      If element is playing it will delegate actual processing to handle_buffer/3.

      Otherwise it will silently drop the buffer.
      """
      def handle_info({:membrane_buffer, {caps, data}}, %{playback_state: playback_state, lement_state: element_state} = state) do
        # debug("Incoming buffer: caps = #{inspect(caps)}, byte_size(data) = #{byte_size(data)}, data = #{inspect(data)}")

        case playback_state do
          :playing ->
            case handle_buffer(caps, data, element_state) do
              {:ok, new_element_state} ->
                {:noreply, %{state | element_state: new_element_state}}

              # TODO handle errors
            end

          :stopped ->
            {:noreply, state}
        end
      end
    end
  end
end