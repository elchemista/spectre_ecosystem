defmodule Spectre.Ecosystem.Manifest do
  @moduledoc """
  Loads the reviewed GitHub repository registry.

  The registry is closed and data-only. It contains repository coordinates,
  workflow ownership and dependency ordering; it contains no local checkout or
  package-execution configuration.
  """

  alias __MODULE__.Package
  alias Spectre.Ecosystem.JSON

  @schema 1
  @name ~r/\Aspectre(?:_[a-z0-9]+)+\z/
  @owner ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\z/
  @ref ~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]{0,199}\z/
  @workflow ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,199}\.ya?ml\z/

  defmodule Package do
    @moduledoc false
    @enforce_keys [:name, :repository, :default_ref, :dependencies, :timeout_minutes]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            name: String.t(),
            repository: String.t(),
            default_ref: String.t(),
            dependencies: [String.t()],
            timeout_minutes: pos_integer()
          }
  end

  @enforce_keys [:path, :owner, :orchestrator, :runtime, :core, :profiles, :packages]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          path: Path.t(),
          owner: String.t(),
          orchestrator: %{
            repository: String.t(),
            default_ref: String.t(),
            workflow: String.t(),
            satellite_workflow: String.t()
          },
          runtime: %{max_parallel: pos_integer()},
          core: Package.t(),
          profiles: [String.t()],
          packages: [Package.t()]
        }

  @doc "Returns the manifest selected for this invocation."
  @spec default_path() :: Path.t()
  def default_path do
    candidates = [
      present(System.get_env("SPECTRE_ECOSYSTEM_MANIFEST")),
      Path.join(File.cwd!(), "ecosystem.json"),
      escript_manifest_path()
    ]

    Enum.find(candidates, Path.join(File.cwd!(), "ecosystem.json"), fn
      nil -> false
      path -> File.regular?(path)
    end)
  end

  @doc "Loads, normalizes and validates a manifest."
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path \\ default_path()) when is_binary(path) do
    expanded = Path.expand(path)

    with {:ok, bytes} <- File.read(expanded),
         {:ok, data} <- JSON.decode(bytes),
         {:ok, manifest} <- normalize(data, expanded),
         :ok <- validate(manifest) do
      {:ok, manifest}
    else
      {:error, :enoent} -> {:error, {:manifest_not_found, expanded}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Validates normalized registry data."
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = manifest) do
    with :ok <- validate_owner(manifest.owner),
         :ok <- validate_orchestrator(manifest),
         :ok <- validate_runtime(manifest.runtime),
         :ok <- validate_profiles(manifest.profiles),
         :ok <- validate_core(manifest),
         :ok <- validate_packages(manifest),
         :ok <- validate_graph(manifest) do
      :ok
    end
  end

  @doc "Returns one satellite by name."
  @spec fetch_package(t(), String.t()) :: {:ok, Package.t()} | {:error, term()}
  def fetch_package(%__MODULE__{} = manifest, name) when is_binary(name) do
    case Enum.find(manifest.packages, &(&1.name == name)) do
      nil -> {:error, {:unknown_package, name}}
      package -> {:ok, package}
    end
  end

  @doc "Returns the core or a satellite by name."
  @spec fetch_component(t(), String.t()) :: {:ok, Package.t()} | {:error, term()}
  def fetch_component(%__MODULE__{core: %{name: name} = core}, name), do: {:ok, core}
  def fetch_component(%__MODULE__{} = manifest, name), do: fetch_package(manifest, name)

  @doc "Returns satellites in stable dependency order."
  @spec ordered_packages(t()) :: [Package.t()]
  def ordered_packages(%__MODULE__{} = manifest) do
    packages = Map.new(manifest.packages, &{&1.name, &1})

    {names, _visited} =
      Enum.reduce(manifest.packages, {[], MapSet.new()}, fn package, state ->
        visit(package.name, packages, state)
      end)

    Enum.map(names, &Map.fetch!(packages, &1))
  end

  @doc "Selects satellites while preserving dependency order."
  @spec select_packages(t(), :all | [String.t()]) ::
          {:ok, [Package.t()]} | {:error, term()}
  def select_packages(%__MODULE__{} = manifest, :all), do: {:ok, ordered_packages(manifest)}

  def select_packages(%__MODULE__{} = manifest, names) when is_list(names) do
    requested = Enum.uniq(names)
    known = MapSet.new(manifest.packages, & &1.name)
    unknown = Enum.reject(requested, &MapSet.member?(known, &1))

    if unknown == [] do
      selected = MapSet.new(requested)
      {:ok, Enum.filter(ordered_packages(manifest), &MapSet.member?(selected, &1.name))}
    else
      {:error, {:unknown_packages, Enum.sort(unknown)}}
    end
  end

  @doc "Checks that a profile belongs to the reviewed registry."
  @spec profile(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def profile(%__MODULE__{profiles: profiles}, value) do
    if value in profiles, do: {:ok, value}, else: {:error, {:unknown_profile, value}}
  end

  defp normalize(%{"schema" => @schema} = data, path) do
    with :ok <-
           exact_keys(
             data,
             ~w(schema owner orchestrator runtime core profiles packages),
             :manifest
           ),
         {:ok, orchestrator} <- normalize_orchestrator(data["orchestrator"]),
         {:ok, runtime} <- normalize_runtime(data["runtime"]),
         {:ok, core} <- normalize_core(data["core"]),
         {:ok, profiles} <- normalize_profiles(data["profiles"]),
         {:ok, packages} <- normalize_packages(data["packages"]) do
      {:ok,
       %__MODULE__{
         path: path,
         owner: data["owner"],
         orchestrator: orchestrator,
         runtime: runtime,
         core: core,
         profiles: profiles,
         packages: packages
       }}
    end
  end

  defp normalize(%{"schema" => schema}, _path),
    do: {:error, {:unsupported_manifest_schema, schema}}

  defp normalize(_data, _path), do: {:error, :invalid_manifest}

  defp normalize_orchestrator(data) when is_map(data) do
    keys = ~w(repository default_ref workflow satellite_workflow)

    with :ok <- exact_keys(data, keys, :orchestrator) do
      {:ok,
       %{
         repository: data["repository"],
         default_ref: data["default_ref"],
         workflow: data["workflow"],
         satellite_workflow: data["satellite_workflow"]
       }}
    end
  end

  defp normalize_orchestrator(_data), do: {:error, :invalid_orchestrator}

  defp normalize_runtime(data) when is_map(data) do
    with :ok <- exact_keys(data, ["max_parallel"], :runtime) do
      {:ok, %{max_parallel: data["max_parallel"]}}
    end
  end

  defp normalize_runtime(_data), do: {:error, :invalid_runtime}

  defp normalize_core(data) when is_map(data) do
    with :ok <- exact_keys(data, ~w(name repository default_ref), :core) do
      {:ok,
       %Package{
         name: data["name"],
         repository: data["repository"],
         default_ref: data["default_ref"],
         dependencies: [],
         timeout_minutes: 1
       }}
    end
  end

  defp normalize_core(_data), do: {:error, :invalid_core}

  defp normalize_profiles(values) when is_list(values), do: {:ok, values}
  defp normalize_profiles(_values), do: {:error, :invalid_profiles}

  defp normalize_packages(values) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case normalize_package(value, index) do
        {:ok, package} -> {:cont, {:ok, [package | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, packages} -> {:ok, Enum.reverse(packages)}
      error -> error
    end
  end

  defp normalize_packages(_values), do: {:error, :invalid_packages}

  defp normalize_package(data, index) when is_map(data) do
    keys = ~w(name repository default_ref dependencies timeout_minutes)

    with :ok <- exact_keys(data, keys, {:package, index}) do
      {:ok,
       %Package{
         name: data["name"],
         repository: data["repository"],
         default_ref: data["default_ref"],
         dependencies: data["dependencies"],
         timeout_minutes: data["timeout_minutes"]
       }}
    end
  end

  defp normalize_package(_data, index), do: {:error, {:invalid_package, index}}

  defp validate_owner(owner) do
    if is_binary(owner) and Regex.match?(@owner, owner), do: :ok, else: {:error, :invalid_owner}
  end

  defp validate_orchestrator(manifest) do
    value = manifest.orchestrator

    with :ok <- repository(value.repository, manifest.owner),
         :ok <- default_ref(value.default_ref),
         :ok <- workflow(value.workflow),
         :ok <- workflow(value.satellite_workflow) do
      :ok
    else
      {:error, reason} -> {:error, {:invalid_orchestrator, reason}}
    end
  end

  defp validate_runtime(%{max_parallel: value}) when is_integer(value) and value in 1..20,
    do: :ok

  defp validate_runtime(_runtime), do: {:error, :invalid_runtime}

  defp validate_profiles(profiles) do
    valid =
      profiles == Enum.uniq(profiles) and profiles != [] and
        Enum.all?(profiles, &(is_binary(&1) and Regex.match?(~r/\A[a-z][a-z0-9_-]{0,31}\z/, &1))) and
        Enum.all?(~w(compat full), &(&1 in profiles))

    if valid, do: :ok, else: {:error, :invalid_profiles}
  end

  defp validate_core(%{core: core, owner: owner}) do
    with true <- core.name == "spectre",
         :ok <- repository(core.repository, owner),
         true <- repository_name(core.repository) == core.name,
         :ok <- default_ref(core.default_ref) do
      :ok
    else
      _other -> {:error, :invalid_core}
    end
  end

  defp validate_packages(%{packages: []}), do: {:error, :empty_packages}

  defp validate_packages(%{packages: packages, owner: owner}) do
    names = Enum.map(packages, & &1.name)
    repositories = Enum.map(packages, & &1.repository)

    with :ok <- duplicates(names, :duplicate_packages),
         :ok <- duplicates(repositories, :duplicate_repositories),
         :ok <- each_package(packages, owner) do
      :ok
    end
  end

  defp each_package(packages, owner) do
    Enum.reduce_while(packages, :ok, fn package, :ok ->
      case validate_package(package, owner) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_package, package.name, reason}}}
      end
    end)
  end

  defp validate_package(package, owner) do
    cond do
      not is_binary(package.name) or not Regex.match?(@name, package.name) ->
        {:error, :invalid_name}

      repository(package.repository, owner) != :ok ->
        {:error, :invalid_repository}

      repository_name(package.repository) != package.name ->
        {:error, :repository_name_mismatch}

      default_ref(package.default_ref) != :ok ->
        {:error, :invalid_default_ref}

      not is_list(package.dependencies) or
          not Enum.all?(package.dependencies, &valid_dependency?/1) ->
        {:error, :invalid_dependencies}

      length(package.dependencies) != length(Enum.uniq(package.dependencies)) ->
        {:error, :duplicate_dependencies}

      package.name in package.dependencies ->
        {:error, :self_dependency}

      not is_integer(package.timeout_minutes) or package.timeout_minutes not in 1..50 ->
        {:error, :invalid_timeout}

      true ->
        :ok
    end
  end

  defp validate_graph(manifest) do
    known = MapSet.new([manifest.core.name | Enum.map(manifest.packages, & &1.name)])

    with :ok <- validate_dependencies(manifest.packages, known),
         :ok <- detect_cycles(manifest.packages) do
      :ok
    end
  end

  defp validate_dependencies(packages, known) do
    Enum.reduce_while(packages, :ok, fn package, :ok ->
      unknown = Enum.reject(package.dependencies, &MapSet.member?(known, &1))

      if unknown == [] do
        {:cont, :ok}
      else
        {:halt, {:error, {:unknown_dependencies, package.name, Enum.sort(unknown)}}}
      end
    end)
  end

  defp detect_cycles(packages) do
    graph =
      Map.new(
        packages,
        &{&1.name, Enum.reject(&1.dependencies, fn name -> name == "spectre" end)}
      )

    Enum.reduce_while(Map.keys(graph), {:ok, MapSet.new()}, fn name, {:ok, done} ->
      case cycle_visit(name, graph, done, MapSet.new()) do
        {:ok, next_done} -> {:cont, {:ok, next_done}}
        {:error, cycle} -> {:halt, {:error, {:dependency_cycle, cycle}}}
      end
    end)
    |> case do
      {:ok, _done} -> :ok
      error -> error
    end
  end

  defp cycle_visit(name, graph, done, active) do
    cond do
      MapSet.member?(done, name) ->
        {:ok, done}

      MapSet.member?(active, name) ->
        {:error, name}

      true ->
        active = MapSet.put(active, name)

        graph
        |> Map.get(name, [])
        |> Enum.reduce_while({:ok, done}, fn dependency, {:ok, acc} ->
          case cycle_visit(dependency, graph, acc, active) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, _name} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, next} -> {:ok, MapSet.put(next, name)}
          error -> error
        end
    end
  end

  defp visit(name, packages, {ordered, visited}) do
    if MapSet.member?(visited, name) do
      {ordered, visited}
    else
      package = Map.fetch!(packages, name)

      state =
        package.dependencies
        |> Enum.filter(&Map.has_key?(packages, &1))
        |> Enum.reduce({ordered, visited}, fn dependency, acc ->
          visit(dependency, packages, acc)
        end)

      {current, seen} = state
      {current ++ [name], MapSet.put(seen, name)}
    end
  end

  defp exact_keys(map, expected, context) do
    actual = Map.keys(map)
    unknown = actual -- expected
    missing = expected -- actual

    cond do
      unknown != [] -> {:error, {:unknown_manifest_keys, context, Enum.sort(unknown)}}
      missing != [] -> {:error, {:missing_manifest_keys, context, Enum.sort(missing)}}
      true -> :ok
    end
  end

  defp duplicates(values, tag) do
    duplicate_values =
      values
      |> Enum.frequencies()
      |> Enum.filter(fn {_value, count} -> count > 1 end)
      |> Enum.map(fn {value, _count} -> value end)
      |> Enum.sort()

    if duplicate_values == [], do: :ok, else: {:error, {tag, duplicate_values}}
  end

  defp valid_dependency?("spectre"), do: true
  defp valid_dependency?(value), do: is_binary(value) and Regex.match?(@name, value)

  defp repository(value, owner) when is_binary(value) and is_binary(owner) do
    case String.split(value, "/", parts: 2) do
      [^owner, name] when name != "" ->
        if Regex.match?(@name, name) or name in ["spectre", "spectre_ecosystem"],
          do: :ok,
          else: {:error, :invalid_repository}

      _other ->
        {:error, :invalid_repository}
    end
  end

  defp repository(_value, _owner), do: {:error, :invalid_repository}

  defp repository_name(value), do: value |> String.split("/") |> List.last()

  defp default_ref(value) do
    if is_binary(value) and Regex.match?(@ref, value),
      do: :ok,
      else: {:error, :invalid_default_ref}
  end

  defp workflow(value) do
    if is_binary(value) and Regex.match?(@workflow, value),
      do: :ok,
      else: {:error, :invalid_workflow}
  end

  defp escript_manifest_path do
    case :escript.script_name() do
      [] -> nil
      name -> name |> to_string() |> Path.dirname() |> Path.join("ecosystem.json")
    end
  rescue
    _error -> nil
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil
end
