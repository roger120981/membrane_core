defmodule Membrane.Testing.Pipeline do
  @moduledoc """
  This Pipeline was created to reduce testing boilerplate and ease communication
  with its elements. It also provides utility for receiving messages when
  `Pipeline` playback state changes and notifications it receives.

  When you want a build Pipeline to test your elements you need three things:
   - Pipeline Module
   - List of elements
   - Links between those elements

  When creating pipelines for tests the only essential part is the list of
   elements. In most cases during the tests, elements are linked in a way that
  `:output` pad is linked to `:input` pad of subsequent element. So we only need
   to pass a list of elements and links can be generated automatically.

  To start a testing pipeline you need to build
  `Membrane.Testing.Pipeline.Options` struct and pass to
  `Membrane.Testing.Pipeline.start_link/2`. Links are generated by
  `populate_links/1`.

  ```
  options = %Membrane.Testing.Pipeline.Options {
    elements: [
      el1: MembraneElement1,
      el2: MembraneElement2,
      ...
    ]
  }
  {:ok, pipeline} = Membrane.Testing.Pipeline.start_link(options)
  ```

  If you need to pass custom links, you can always do it using `:links` field of
  `Membrane.Testing.Pipeline.Options` struct.

  ```
  options = %Membrane.Testing.Pipeline.Options {
    elements: [
      el1: MembraneElement1,
      el2: MembraneElement2,
      ],
      links: %{
        {:el1, :output} => {:el2, :input}
      }
    }
    ```

  See `Membrane.Testing.Pipeline.Options` for available options.

  ## Example usage

  Once options are created we can start the pipeline.

      options = %Membrane.Testing.Pipeline.Options {
        elements: [
          source: %Membrane.Testing.Source{},
          tested_element: TestedElement,
          sink: %Membrane.Testing.Sink{}
        ]
      }
      {:ok, pipeline} = Membrane.Testing.Pipeline.start_link(options)


  We can now wait till the end of the stream reaches the sink element.

      assert_end_of_stream(pipeline, :sink)

  We can also assert that the `Membrane.Testing.Sink` processed a specific
  buffer.

      assert_sink_buffer(pipeline, :sink ,%Membrane.Buffer{payload: 1})

  ## Assertions

  Using this module enables usage of various assertions which are described in
  detail in `Membrane.Testing.Assertions`.

  ## Messaging children

  You can send messages to children using their names specified in the elements
  list. Please check `message_child/3` for more details.

  """

  use Membrane.Pipeline

  alias Membrane.{Element, Pipeline}
  alias Membrane.Pipeline.Spec

  defmodule Options do
    @moduledoc """
    Structure representing `options` passed to testing pipeline.

    ##  Test Process
    `pid` of process that shall receive messages when Pipeline invokes playback
    state change callback and receives notification.

    ## Elements
    List of element specs.

    ## Links
    Map describing links between elements.

    If links are not present or set to nil they will be populated automatically
    based on elements order using default pad names.
    """

    @enforce_keys [:elements]
    defstruct @enforce_keys ++ [:links, :test_process, :custom_pipeline]

    @type t :: %__MODULE__{
            test_process: pid() | nil,
            elements: Spec.children_spec_t(),
            links: Spec.links_spec_t() | nil,
            custom_pipeline: module() | nil
          }
  end

  def start_link(pipeline_options, process_options \\ []) do
    Pipeline.start_link(__MODULE__, default_options(pipeline_options), process_options)
  end

  def start(pipeline_options, process_options \\ []) do
    Pipeline.start(__MODULE__, default_options(pipeline_options), process_options)
  end

  defp default_options(%Options{test_process: nil} = options),
    do: %Options{options | test_process: self()}

  defp default_options(default), do: default

  @doc """
  Links subsequent elements using default pads (linking `:input` to `:output` of
  previous element).

  ## Example

      iex> Pipeline.populate_links([el1: MembraneElement1, el2: MembraneElement2])
      %{{:el1, :output} => {:el2, :input}}
  """
  @spec populate_links(elements :: Spec.children_spec_t()) :: Spec.links_spec_t()
  def populate_links(elements) do
    elements
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{output_name, _}, {input_name, _}] ->
      {{output_name, :output}, {input_name, :input}}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Sends message to a child by Element name.

  ## Example

  Knowing that `pipeline` has child named `sink`, message can be sent as follows:

      message_child(pipeline, :sink, {:message, "to handle"})
  """
  @spec message_child(pid(), Element.name_t(), any()) :: :ok
  def message_child(pipeline, child, message) do
    send(pipeline, {:for_element, child, message})
    :ok
  end

  @impl true
  def handle_init(%Options{links: nil, elements: elements} = options) do
    new_links = populate_links(elements)
    handle_init(%Options{options | links: new_links})
  end

  def handle_init(args) do
    %Options{elements: elements, links: links} = args

    spec = %Membrane.Pipeline.Spec{
      children: elements,
      links: links
    }

    new_state = Map.take(args, [:test_process, :custom_pipeline])

    new_state =
      Map.put(
        new_state,
        :custom_pipeline_state,
        pipeline_eval(:handle_init, args, nil, nil, new_state)
      )

    {{:ok, spec}, new_state}
  end

  defp wrap_result(result) do
    case result do
      {:ok, state} -> {{:ok, []}, state}
      {{reaction, actions}, state} -> {{reaction, actions}, state}
    end
  end

  defp pipeline_eval(
         :handle_init,
         _custom_args,
         _function,
         _args,
         %{custom_pipeline: nil} = _state
       ),
       do: nil

  defp pipeline_eval(
         :handle_init,
         custom_args,
         _function,
         _args,
         %{custom_pipeline: pipeline} = _state
       ) do
    with _custom_result = {{:ok, _spec}, state} <-
           apply(pipeline, :handle_init, custom_args)
           |> wrap_result,
         do: state
  end

  defp pipeline_eval(
         _custom_function,
         _custom_args,
         function,
         args,
         %{custom_pipeline: nil} = _state
       ),
       do: apply(function, args)

  defp pipeline_eval(
         custom_function,
         custom_args,
         function,
         args,
         %{custom_pipeline: pipeline} = state
       ) do
    with custom_result = {{:ok, _actions}, _state} <-
           apply(pipeline, custom_function, custom_args ++ state[:custom_pipeline_state])
           |> wrap_result do
      result = apply(function, args)
      combine_results(custom_result, result)
    end
  end

  defp combine_actions(l, r) do
    case {l, r} do
      {l, :ok} -> l
      {:ok, r} -> r
      {{:ok, actions_l}, {:ok, actions_r}} -> {:ok, actions_l ++ actions_r}
      {{:ok, _actions_l}, r} -> r
      {l, {:ok, _actions_r}} -> l
      {l, _r} -> l
    end
  end

  defp combine_results({actions_l, state_l}, {actions_r, state_r}),
    do: {combine_actions(actions_l, actions_r), Map.put(state_l, :custom_pipeline_state, state_r)}

  @impl true
  def handle_stopped_to_prepared(state),
    do:
      pipeline_eval(
        :handle_stopped_to_prepared,
        [],
        &notify_playback_state_changed/3,
        [:stopped, :prepared, state],
        state
      )

  @impl true
  def handle_prepared_to_playing(state),
    do:
      pipeline_eval(
        :handle_prepared_to_playing,
        [],
        &notify_playback_state_changed/3,
        [:prepared, :playing, state],
        state
      )

  @impl true
  def handle_playing_to_prepared(state),
    do:
      pipeline_eval(
        :handle_playing_to_prepared,
        [],
        &notify_playback_state_changed/3,
        [:playing, :prepared, state],
        state
      )

  @impl true
  def handle_prepared_to_stopped(state),
    do:
      pipeline_eval(
        :handle_prepared_to_stopped,
        [],
        &notify_playback_state_changed/3,
        [:prepared, :stopped, state],
        state
      )

  @impl true
  def handle_notification(notification, from, state),
    do:
      pipeline_eval(
        :handle_notification,
        [notification, from],
        &notify_test_process/2,
        [{:handle_notification, {notification, from}}, state],
        state
      )

  @impl true
  def handle_spec_started(elements, state),
    do:
      pipeline_eval(
        :handle_spec_started,
        [elements],
        &do_nothing/2,
        [:ok, state],
        state
      )

  defp do_nothing(actions, state),
    do: {actions, state}

  @impl true
  def handle_other({:for_element, element, message}, state),
    do:
      pipeline_eval(
        :handle_other,
        [{:for_element, element, message}],
        &do_nothing/2,
        [{:ok, forward: {element, message}}, state],
        state
      )

  def handle_other(message, state),
    do:
      pipeline_eval(
        :handle_other,
        [message],
        &notify_test_process/2,
        [{:handle_other, message}, state],
        state
      )

  defp notify_playback_state_changed(previous, current, state) do
    notify_test_process({:playback_state_changed, previous, current}, state)
  end

  defp notify_test_process(message, %{test_process: test_process} = state) do
    send(test_process, {__MODULE__, self(), message})

    {:ok, state}
  end
end
