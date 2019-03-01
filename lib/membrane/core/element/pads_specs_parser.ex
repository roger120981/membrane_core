defmodule Membrane.Core.Element.PadsSpecsParser do
  @moduledoc false
  # Functions parsing element pads specifications, generating functions and docs
  # based on them.
  alias Membrane.{Caps, Element}
  alias Element.Pad
  alias Bunch.Type
  use Bunch

  def def_pads(pads, direction) do
    pads
    |> Enum.reduce(
      quote do
      end,
      fn {name, spec}, acc ->
        pad_def = def_pad(name, direction, spec)

        quote do
          unquote(acc)
          unquote(pad_def)
        end
      end
    )
  end

  # Generates `membrane_pads/0` function, along with docs and typespecs.
  @spec def_pad(Pad.name_t(), Pad.direction_t(), Macro.t()) :: Macro.t()
  def def_pad(name, direction, raw_specs) do
    Code.ensure_loaded(Caps.Matcher)

    specs =
      raw_specs
      |> Bunch.Macro.inject_calls([
        {Caps.Matcher, :one_of},
        {Caps.Matcher, :range}
      ])

    quote do
      if Module.get_attribute(__MODULE__, :membrane_pad) == nil do
        Module.register_attribute(__MODULE__, :membrane_pad, accumulate: true)
        @before_compile {unquote(__MODULE__), :generate_membrane_pads}
      end

      @membrane_pad unquote(__MODULE__).parse_pad_specs!(
                      {unquote(name), unquote(specs)},
                      unquote(direction),
                      __ENV__
                    )
    end
  end

  defmacro generate_membrane_pads(env) do
    :ok = validate_pads!(Module.get_attribute(env.module, :membrane_pad), env)

    quote do
      @doc """
      Returns pads specification for `#{inspect(__MODULE__)}`

      They are the following:
        #{@membrane_pad |> unquote(__MODULE__).generate_docs_from_pads_specs()}
      """
      @spec membrane_pads() :: [
              {Membrane.Element.Pad.name_t(), Membrane.Element.Pad.description_t()}
            ]
      def membrane_pads() do
        @membrane_pad
      end
    end
  end

  @spec validate_pads!(
          pads :: [{Pad.name_t(), Pad.description_t()}],
          env :: Macro.Env.t()
        ) :: :ok
  defp validate_pads!(pads, env) do
    with [] <- pads |> Keyword.keys() |> Bunch.Enum.duplicates() do
      :ok
    else
      dups ->
        raise CompileError, file: env.file, description: "Duplicate pad names: #{inspect(dups)}"
    end
  end

  @spec parse_pad_specs!(
          specs :: Pad.spec_t(),
          direction :: Pad.direction_t(),
          declaration_env :: Macro.Env.t()
        ) :: {Pad.name_t(), Pad.description_t()}
  def parse_pad_specs!(specs, direction, env) do
    with {:ok, specs} <- parse_pad_specs(specs, direction) do
      specs
    else
      {:error, reason} ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: """
          Error parsing pad specs defined in #{inspect(env.module)}.def_#{direction}_pads/1,
          reason: #{inspect(reason)}
          """
    end
  end

  @spec parse_pad_specs(Pad.spec_t(), Pad.direction_t()) ::
          Type.try_t({Pad.name_t(), Pad.description_t()})
  def parse_pad_specs(spec, direction) do
    withl spec: {name, config} when is_atom(name) and is_list(config) <- spec,
          config:
            {:ok, config} <-
              Bunch.Config.parse(config,
                availability: [in: [:always, :on_request], default: :always],
                caps: [validate: &Caps.Matcher.validate_specs/1],
                mode: [in: [:pull, :push], default: :pull],
                demand_unit: [
                  in: [:buffers, :bytes],
                  require_if: &(&1.mode == :pull and direction == :input)
                ]
              ) do
      {:ok, {name, Map.put(config, :direction, direction)}}
    else
      spec: spec -> {:error, {:invalid_pad_spec, spec}}
      config: {:error, reason} -> {:error, {reason, pad: name}}
    end
  end

  # Generates docs describing pads, based on pads specification.
  @spec generate_docs_from_pads_specs(Pad.description_t()) :: String.t()
  def generate_docs_from_pads_specs(pads_specs) do
    pads_specs
    |> Enum.map(&generate_docs_from_pad_specs/1)
    |> Enum.join("\n")
  end

  defp generate_docs_from_pad_specs({name, config}) do
    """
    * Pad `#{inspect(name)}`
    #{
      config
      |> Enum.map(fn {k, v} ->
        "* #{k |> to_string() |> String.replace("_", " ")}: #{generate_pad_property_doc(k, v)}"
      end)
      |> Enum.join("\n")
      |> indent(2)
    }
    """
  end

  defp generate_pad_property_doc(:caps, caps) do
    caps
    |> Bunch.listify()
    |> Enum.map(fn
      {module, params} ->
        params_doc =
          params |> Enum.map(fn {k, v} -> "`#{k}`:&nbsp;`#{inspect(v)}`" end) |> Enum.join(", ")

        "`#{inspect(module)}`, params: #{params_doc}"

      module ->
        "`#{inspect(module)}`"
    end)
    ~> (
      [doc] -> doc
      docs -> docs |> Enum.map(&"\n* #{&1}") |> Enum.join()
    )
    |> indent()
  end

  defp generate_pad_property_doc(_k, v) do
    "`#{inspect(v)}`"
  end

  defp indent(string, size \\ 1) do
    string
    |> String.split("\n")
    |> Enum.map(&(String.duplicate("  ", size) <> &1))
    |> Enum.join("\n")
  end
end
