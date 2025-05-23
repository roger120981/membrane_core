defmodule Membrane.Support.Element.DynamicFilter do
  @moduledoc """
  This is a mock filter with dynamic inputs for use in specs.

  Modify with caution as many specs may depend on its shape.
  """

  use Bunch
  use Membrane.Filter, flow_control_hints?: false

  def_input_pad :input, accepted_format: _any, availability: :on_request, flow_control: :auto
  def_output_pad :output, accepted_format: _any, availability: :on_request, flow_control: :auto

  @impl true
  def handle_init(_ctx, _options) do
    {[], %{}}
  end

  @impl true
  def handle_pad_added(pad, _ctx, state) do
    {[notify_parent: {:pad_added, pad}], state |> Map.put(:last_pad_addded, pad)}
  end

  @impl true
  def handle_pad_removed(pad, _ctx, state) do
    {[notify_parent: {:pad_removed, pad}], state |> Map.put(:last_pad_removed, pad)}
  end

  @impl true
  def handle_event(ref, event, _ctx, state) do
    {[forward: event], state |> Map.put(:last_event, {ref, event})}
  end

  @impl true
  def handle_end_of_stream(_pad_ref, ctx, state) do
    actions =
      Enum.flat_map(ctx.pads, fn
        {pad_ref, %{direction: :output, end_of_stream?: false}} -> [end_of_stream: pad_ref]
        _other -> []
      end)

    {actions, state}
  end
end
