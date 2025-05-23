defmodule Membrane.Pipeline do
  @moduledoc """
  A behaviour module for implementing pipelines.

  `Membrane.Pipeline` contains the callbacks and functions for constructing and supervising pipelines.
  Pipelines facilitate the convenient instantiation, linking, and management of elements and bins.\\
  Linking pipeline children together enables them to pass and process data.

  To create a pipeline, use `use Membrane.Pipeline` and implement callbacks of `Membrane.Pipeline`  behaviour.
  See `Membrane.ChildrenSpec` for details on instantiating and linking children.
  ## Starting and supervision

  Start a pipeline with `start_link/2` or `start/2`. Pipelines always spawn under a dedicated supervisor, so
  in the case of success, either function will return `{:ok, supervisor_pid, pipeline_pid}` .

  The supervisor never restarts the pipeline, but it does ensure that the pipeline and its children terminate properly.
  If the pipeline needs to be restarted, it should be spawned under a different supervisor with the appropriate strategy.

  ### Starting under a supervision tree

   A pipeline can be spawned under a supervision tree like any other `GenServer`.\\
   `use Membrane.Pipeline` injects a `child_spec/1` function. A simple scenario could look like this:

      defmodule MyPipeline do
        use Membrane.Pipeline

        def start_link(options) do
          Membrane.Pipeline.start_link(__MODULE__, options, name: MyPipeline)
        end

        # ...
      end

      Supervisor.start_link([{MyPipeline, option: :value}], strategy: :one_for_one)
      send(MyPipeline, :message)

  ### Starting outside of a supervision tree

  When starting a pipeline outside a supervision tree, use the `pipeline_pid` pid to interact with the pipeline.
   A simple scenario could look like this:

      {:ok, _supervisor_pid, pipeline_pid} = Membrane.Pipeline.start_link(MyPipeline, option: :value)
      send(pipeline_pid, :message)

  ### Visualizing the supervision tree

  Use the [Applications tab](https://www.erlang.org/doc/apps/observer/observer_ug#applications-tab) in Erlang's Observer GUI
  (or the `Kino` library in Livebook) to visualize a pipeline's internal supervision tree. Use the following configuration for debugging purposes only:

        config :membrane_core, unsafely_name_processes_for_observer: [:components]

  This improves the readability of the Observer's process tree graph by naming the pipeline descendants, as demonstrated here:

  ![Observer graph](assets/images/observer_graph.png).
  """

  use Bunch

  alias __MODULE__.{Action, CallbackContext}
  alias Membrane.{Child, Pad, PipelineError}

  require Membrane.Logger
  require Membrane.Core.Message, as: Message

  @typedoc """
  Defines options passed to the `start/3` and `start_link/3` and subsequently received
  in the `c:handle_init/2` callback.
  """
  @type pipeline_options :: any

  @typedoc "The Pipeline name"
  @type name :: GenServer.name()

  @typedoc "List of configurations used by `start/3` and `start_link/3`."
  @type config :: [config_entry()]

  @typedoc "Defines configuration value used by the `start/3` and `start_link/3`."
  @type config_entry :: {:name, name()}

  @typedoc """
  Defines the return value of the `start/3` and `start_link/3`."
  """
  @type on_start ::
          {:ok, supervisor_pid :: pid, pipeline_pid :: pid}
          | {:error, {:already_started, pid()} | term()}

  @typedoc """
  The pipeline state.
  """
  @type state :: any()

  @typedoc """
  Defines return values from Pipeline callback functions.

  ## Return values

    * `{[action], state}` - Returns a list of actions that will be performed within the
      pipeline, e.g., starting new children, sending messages to specific children, etc.
      Actions are tuples of `{type, arguments}`, so they can be expressed as a keyword list.
      See `Membrane.Pipeline.Action` for more info.
  """
  @type callback_return ::
          {[Action.t()], state}

  @doc """
  Callback invoked on initialization of the pipeline.

  This callback is synchronous: the process that started the pipeline waits until `handle_init`
  finishes, so it's important to do any long-lasting or complex work in `c:handle_setup/2`.
  `handle_init` should be used for things, like parsing options, initializing state, or spawning
  children. By default, `handle_init` converts `opts` to a map if they're a struct and sets them as the pipeline state.
  """
  @callback handle_init(context :: CallbackContext.t(), options :: pipeline_options) ::
              {[Action.common_actions()], state()}

  @doc """
  Callback invoked when the pipeline is requested to terminate with `terminate/2`.
  By default, it returns `t:Membrane.Pipeline.Action.terminate/0` with reason `:normal`.
  """
  @callback handle_terminate_request(context :: CallbackContext.t(), state) ::
              {[Action.common_actions()], state()}

  @doc """
  Callback invoked on pipeline startup, right after `c:handle_init/2`.

  Any long-lasting or complex initialization should happen here.
  By default, it does nothing.
  """
  @callback handle_setup(
              context :: CallbackContext.t(),
              state
            ) ::
              {[Action.common_actions()], state()}

  @doc """
  Callback invoked when the pipeline switches the playback to `:playing`.
  By default, it does nothing.
  """
  @callback handle_playing(
              context :: CallbackContext.t(),
              state
            ) ::
              {[Action.common_actions()], state()}

  @doc """
  Callback invoked when a child removes its pad.

  The callback won't be invoked, when you have initiated the pad removal,
  eg. when you have returned `t:Membrane.Pipeline.Action.remove_link()`
  action which made one of your children's pads be removed.
  By default, it does nothing.
  """
  @callback handle_child_pad_removed(
              child :: Child.name(),
              pad :: Pad.ref(),
              context :: CallbackContext.t(),
              state :: state
            ) :: {[Action.common_actions()], state()}

  @doc """
  Callback invoked when a notification comes in from a child.

  By default, it ignores the notification.
  """
  @callback handle_child_notification(
              notification :: Membrane.ChildNotification.t(),
              element :: Child.name(),
              context :: CallbackContext.t(),
              state
            ) :: {[Action.common_actions()], state()}

  @doc """
  Callback invoked when the pipeline receives a message that is not recognized
  as an internal Membrane message.

  Useful for receiving data sent from NIFs or other external sources.
  By default, it logs and ignores the received message.
  """
  @callback handle_info(
              message :: any,
              context :: CallbackContext.t(),
              state
            ) ::
              {[Action.common_actions()], state()}

  @doc """
  Callback invoked when a child element starts processing a stream via the given pad.

  By default, it does nothing.
  """
  @callback handle_element_start_of_stream(
              child :: Child.name(),
              pad :: Pad.ref(),
              context :: CallbackContext.t(),
              state
            ) :: {[Action.common_actions()], state()}

  @doc """
  Callback invoked when a child element finishes processing a stream via the given pad.

  By default, it does nothing.
  """
  @callback handle_element_end_of_stream(
              child :: Child.name(),
              pad :: Pad.ref(),
              context :: CallbackContext.t(),
              state
            ) :: {[Action.common_actions()], state()}

  @doc """
  This callback is deprecated since v1.1.0.

  Callback invoked when children of `Membrane.ChildrenSpec` are started.

  It is invoked, only if pipeline module contains its definition. Otherwise, nothing happens.
  """
  @callback handle_spec_started(
              children :: [Child.name()],
              context :: CallbackContext.t(),
              state
            ) :: {[Action.common_actions()], state()}

  @doc """
  Callback invoked when a child completes its setup.

  By default, it does nothing.
  """
  @callback handle_child_setup_completed(
              child :: Child.name(),
              context :: CallbackContext.t(),
              state
            ) :: {[Action.common_actions()], state()}

  @doc """
  Callback invoked when a child enters `playing` playback.

  By default, it does nothing.
  """
  @callback handle_child_playing(
              child :: Child.name(),
              context :: CallbackContext.t(),
              state
            ) :: {[Action.common_actions()], state()}

  @doc """
  Callback invoked after a child terminates.

  Terminated child won't be present in the context of this callback. It is allowed to spawn a new child
  with the same name.

  By default, it does nothing.
  """
  @callback handle_child_terminated(
              child :: Child.name(),
              context :: CallbackContext.t(),
              state
            ) :: callback_return

  @doc """
  Callback invoked upon each timer tick. A timer can be started with `Membrane.Pipeline.Action.start_timer`
  action.
  """
  @callback handle_tick(
              timer_id :: any,
              context :: CallbackContext.t(),
              state
            ) :: {[Action.common_actions()], state()}

  @doc """
  Callback invoked when a crash group crashes.

  Context passed to this callback contains 2 additional fields: `:members` and `:crash_initiator`.
  By default, it does nothing.
  """
  @callback handle_crash_group_down(
              group_name :: Child.group(),
              context :: CallbackContext.t(),
              state
            ) :: {[Action.common_actions()], state()}

  @doc """
  Callback invoked when the pipeline is called using a synchronous call.

  Context passed to this callback contains an additional field `:from`.
  By default, it does nothing.
  """
  @callback handle_call(
              message :: any,
              context :: CallbackContext.t(),
              state
            ) ::
              {[Action.common_actions() | Action.reply()], state()}

  @optional_callbacks handle_init: 2,
                      handle_setup: 2,
                      handle_playing: 2,
                      handle_info: 3,
                      handle_spec_started: 3,
                      handle_child_setup_completed: 3,
                      handle_child_playing: 3,
                      handle_element_start_of_stream: 4,
                      handle_element_end_of_stream: 4,
                      handle_child_notification: 4,
                      handle_tick: 3,
                      handle_crash_group_down: 3,
                      handle_call: 3,
                      handle_terminate_request: 2,
                      handle_child_pad_removed: 4,
                      handle_child_terminated: 3

  @doc """
  Starts the pipeline based on the given module and links it to the current process.


  Pipeline options are passed to the `c:handle_init/2` callback.
  Note that this function returns `{:ok, supervisor_pid, pipeline_pid}` in case of
  success. Check the 'Starting and supervision' section of the moduledoc for details.
  """
  @spec start_link(module, pipeline_options, config) :: on_start
  def start_link(module, pipeline_options \\ nil, process_options \\ []),
    do: do_start(:start_link, module, pipeline_options, process_options)

  @doc """
  Starts the pipeline outside a supervision tree. Compare to `start_link/3`.
  """
  @spec start(module, pipeline_options, config) :: on_start
  def start(module, pipeline_options \\ nil, process_options \\ []),
    do: do_start(:start, module, pipeline_options, process_options)

  defp do_start(method, module, pipeline_options, process_options) do
    if module |> pipeline? do
      Membrane.Logger.debug("""
      Pipeline start link: module: #{inspect(module)},
      pipeline options: #{inspect(pipeline_options)},
      process options: #{inspect(process_options)}
      """)

      name =
        case Keyword.fetch(process_options, :name) do
          {:ok, name} when is_atom(name) -> Atom.to_string(name)
          _other -> nil
        end
        |> case do
          "Elixir." <> module -> module
          name -> name
        end

      Membrane.Core.Pipeline.Supervisor.run(
        method,
        name,
        &GenServer.start_link(
          Membrane.Core.Pipeline,
          %{
            name: name,
            module: module,
            options: pipeline_options,
            subprocess_supervisor: &1
          },
          process_options
        )
      )
    else
      Membrane.Logger.error("""
      Cannot start pipeline, passed module #{inspect(module)} is not a Membrane Pipeline.
      Make sure that given module is the right one and it uses Membrane.Pipeline
      """)

      {:error, {:not_pipeline, module}}
    end
  end

  @doc """
  Terminates the pipeline.

  Accepts three options:
  * `asynchronous?` - if set to `true`, pipeline termination won't be blocking and
    will be executed in the process whose pid is returned as a function result.
    If set to `false`, pipeline termination will be blocking and will be executed in
    the process that called this function. Defaults to `false`.
  * `timeout` - specifies how much time (ms) to wait for the pipeline to gracefully
    terminate. Defaults to 5000.
  * `force?` - determines how to handle a pipeline still alive after `timeout`.
    If set to `true`, `Process.exit/2` kills the pipeline with reason `:kill` and returns
    `{:error, :timeout}`.
    If set to `false`, it raises an error. Defaults to `false`.

  Returns:
  * `{:ok, pid}` - option `asynchronous?: true` was passed.
  * `:ok` - pipeline gracefully terminated within `timeout`.
  * `{:error, :timeout}` - pipeline was killed after `timeout`.
  """
  @spec terminate(pipeline :: pid,
          timeout: timeout(),
          force?: boolean(),
          asynchronous?: boolean()
        ) ::
          :ok | {:ok, pid()} | {:error, :timeout}
  def terminate(pipeline, opts \\ []) do
    [asynchronous?: asynchronous?] ++ opts =
      Keyword.validate!(opts,
        asynchronous?: false,
        force?: false,
        timeout: 5000
      )
      |> Enum.sort()

    if asynchronous? do
      Task.start(__MODULE__, :do_terminate, [pipeline, opts])
    else
      do_terminate(pipeline, opts)
    end
  end

  @doc false
  @spec do_terminate(pipeline :: pid, timeout: timeout(), force?: boolean()) ::
          :ok | {:error, :timeout}
  def do_terminate(pipeline, opts) do
    timeout = Keyword.get(opts, :timeout)
    force? = Keyword.get(opts, :force?)

    ref = Process.monitor(pipeline)
    Message.send(pipeline, :terminate)

    receive do
      {:DOWN, ^ref, _process, _pid, _reason} ->
        :ok
    after
      timeout ->
        if force? do
          Process.exit(pipeline, :kill)
          {:error, :timeout}
        else
          raise PipelineError, """
          Pipeline #{inspect(pipeline)} hasn't terminated within given timeout (#{inspect(timeout)} ms).
          If you want to kill it anyway, use `force?: true` option.
          """
        end
    end
  end

  @doc """
  Calls the pipeline with a message.

  Returns the result of the pipeline call.
  """
  @spec call(pid, any, timeout()) :: term()
  def call(pipeline, message, timeout \\ 5000) do
    GenServer.call(pipeline, message, timeout)
  end

  @doc """
  Checks whether the module is a pipeline.
  """
  @spec pipeline?(module) :: boolean
  def pipeline?(module) do
    module |> Bunch.Module.check_behaviour(:membrane_pipeline?)
  end

  @doc """
  Returns list of pipeline PIDs currently running on the current node.

  Use for debugging only.
  """
  @spec list_pipelines() :: [pid]
  def list_pipelines() do
    Process.list()
    |> Enum.filter(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} -> List.keyfind(dictionary, :__membrane_pipeline__, 0)
        nil -> false
      end
    end)
  end

  @doc """
  Returns list of pipeline PIDs currently running on the passed node. \\
  Compare to `list_pipelines/0`.
  """
  @spec list_pipelines(node()) :: [pid]
  def list_pipelines(node) do
    :erpc.call(node, __MODULE__, :list_pipelines, [])
  end

  @doc """
  Brings all the stuff necessary to implement a pipeline.

  Options:
    - `:bring_spec?` - if true (default) imports and aliases `Membrane.ChildrenSpec`
    - `:bring_pad?` - if true (default) requires and aliases `Membrane.Pad`
  """
  defmacro __using__(options) do
    bring_spec =
      if Keyword.get(options, :bring_spec?, true) do
        quote do
          import Membrane.ChildrenSpec
          alias Membrane.ChildrenSpec
        end
      end

    bring_pad =
      if Keyword.get(options, :bring_pad?, true) do
        quote do
          require Membrane.Pad
          alias Membrane.Pad
        end
      end

    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote do
      alias unquote(__MODULE__)
      require Membrane.Logger
      @behaviour unquote(__MODULE__)
      @after_compile {Membrane.Core.Parent, :check_deprecated_callbacks}

      unquote(bring_spec)
      unquote(bring_pad)

      @doc """
      Returns child specification for spawning under a supervisor
      """
      # credo:disable-for-next-line Credo.Check.Readability.Specs
      def child_spec(arg) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [arg]},
          type: :supervisor
        }
      end

      @doc false
      @spec membrane_pipeline?() :: true
      def membrane_pipeline?, do: true

      @impl true
      def handle_init(_ctx, %_opt_struct{} = options),
        do: {[], options |> Map.from_struct()}

      @impl true
      def handle_init(_ctx, options), do: {[], options}

      @impl true
      def handle_setup(_ctx, state), do: {[], state}

      @impl true
      def handle_playing(_ctx, state), do: {[], state}

      @impl true
      def handle_info(message, _ctx, state) do
        Membrane.Logger.warning("""
        Received message but no handle_info callback has been specified. Ignoring.
        Message: #{inspect(message)}\
        """)

        {[], state}
      end

      @impl true
      def handle_child_setup_completed(_child, _ctx, state), do: {[], state}

      @impl true
      def handle_child_terminated(_child, _ctx, state), do: {[], state}

      @impl true
      def handle_child_playing(_child, _ctx, state), do: {[], state}

      @impl true
      def handle_element_start_of_stream(_element, _pad, _ctx, state), do: {[], state}

      @impl true
      def handle_element_end_of_stream(_element, _pad, _ctx, state), do: {[], state}

      @impl true
      def handle_child_notification(notification, element, _ctx, state), do: {[], state}

      @impl true
      def handle_crash_group_down(_group_name, _ctx, state), do: {[], state}

      @impl true
      def handle_call(message, _ctx, state), do: {[], state}

      @impl true
      def handle_terminate_request(_ctx, state), do: {[terminate: :normal], state}

      defoverridable child_spec: 1,
                     handle_init: 2,
                     handle_setup: 2,
                     handle_playing: 2,
                     handle_info: 3,
                     handle_child_setup_completed: 3,
                     handle_child_playing: 3,
                     handle_element_start_of_stream: 4,
                     handle_element_end_of_stream: 4,
                     handle_child_notification: 4,
                     handle_crash_group_down: 3,
                     handle_call: 3,
                     handle_terminate_request: 2,
                     handle_child_terminated: 3
    end
  end
end
