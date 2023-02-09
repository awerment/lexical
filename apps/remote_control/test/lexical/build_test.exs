defmodule Lexical.BuildTest do
  alias Lexical.Project
  alias Lexical.RemoteControl
  alias Lexical.RemoteControl.Build
  alias Lexical.RemoteControl.Api.Messages
  alias Lexical.SourceFile
  alias Mix.Task.Compiler.Diagnostic

  import Messages
  use ExUnit.Case

  def fixtures_dir do
    [__ENV__.file, "..", "..", "fixtures"]
    |> Path.join()
    |> Path.expand()
  end

  def compile_source_file(%Project{} = project, filename \\ "file.ex", source_code) do
    uri =
      project
      |> Project.root_path()
      |> Path.join(filename)
      |> SourceFile.Path.to_uri()

    source = SourceFile.new(uri, source_code, 0)
    Build.compile_source_file(project, source)
  end

  def with_project(project_name) do
    project_name = to_string(project_name)
    fixture_dir = Path.join(fixtures_dir(), project_name)
    project = Project.new("file://#{fixture_dir}")

    {:ok, _} = RemoteControl.start_link(project, self())

    assert_receive module_updated(), 5000

    on_exit(fn ->
      :ok = RemoteControl.stop(project)
    end)

    {:ok, project}
  end

  def with_empty_module(%{project: project}) do
    module = ~S[
      defmodule UnderTest do
      end
    ]
    compile_source_file(project, module)
    assert_receive file_compiled(), 5000
    :ok
  end

  def with_metadata_project(_) do
    {:ok, project} = with_project(:project_metadata)
    {:ok, project: project}
  end

  describe "compiling a project" do
    test "sends a message when complete " do
      {:ok, project} = with_project(:project_metadata)
      Build.schedule_compile(project, true)

      assert_receive project_compiled(status: :success), 5000
    end

    test "receives metadata about the defined modules" do
      {:ok, project} = with_project(:project_metadata)

      Build.schedule_compile(project, true)
      assert_receive module_updated(name: name, functions: functions), 5000
      assert name == ProjectMetadata
      assert {:zero_arity, 0} in functions
      assert {:one_arity, 1} in functions
      assert {:two_arity, 2} in functions
    end
  end

  describe "compiling an umbrella project" do
    test "it sends a message when compilation is complete" do
      {:ok, project} = with_project(:umbrella)
      Build.schedule_compile(project, true)

      assert_receive project_compiled(status: :success, diagnostics: []), 5000
      assert_receive module_updated(name: Umbrella.First, functions: functions)

      assert {:arity_0, 0} in functions
      assert {:arity_1, 1} in functions
      assert {:arity_2, 2} in functions

      assert_receive module_updated(name: Umbrella.Second, functions: functions), 500

      assert {:arity_0, 0} in functions
      assert {:arity_1, 1} in functions
      assert {:arity_2, 2} in functions
    end
  end

  describe "compiling a project that has errors" do
    test "it reports the errors" do
      {:ok, project} = with_project(:compilation_errors)
      Build.schedule_compile(project, true)

      assert_receive project_compiled(status: :error, diagnostics: diagnostics), 5000
      assert [%Diagnostic{}] = diagnostics
    end
  end

  describe "when compiling a project that has warnings" do
    test "it reports them" do
      {:ok, project} = with_project(:compilation_warnings)
      Build.schedule_compile(project, true)

      assert_receive project_compiled(status: :error, diagnostics: diagnostics), 5000
      assert [%Diagnostic{}, %Diagnostic{}] = diagnostics
    end
  end

  describe "compiling source files" do
    setup [:with_metadata_project, :with_empty_module]

    test "handles syntax errors", %{project: project} do
      source = ~S[
        defmodule WithErrors do
          def error do
            %{,}
          end
        end
      ]
      compile_source_file(project, source)
      assert_receive file_compiled(status: :error, diagnostics: [diagnostic])
      assert %Diagnostic{} = diagnostic
      assert diagnostic.severity == :error
      assert diagnostic.message =~ ~S[syntax error before: ',']
      assert diagnostic.position == {3, 14}
    end

    test "handles missing token errors", %{project: project} do
      source = ~S[%{foo: 3]
      compile_source_file(project, source)

      assert_receive file_compiled(status: :error, diagnostics: [diagnostic])
      assert %Diagnostic{} = diagnostic
      assert diagnostic.severity == :error
      assert diagnostic.message =~ ~S[missing terminator: }]
      assert diagnostic.position == {0, 8}
    end

    test "handles compile errors", %{project: project} do
      source = ~S[doesnt_exist()]
      compile_source_file(project, source)

      assert_receive file_compiled(status: :error, diagnostics: [diagnostic])
      assert %Diagnostic{} = diagnostic
      assert diagnostic.severity == :error
      assert diagnostic.message =~ ~S[undefined function doesnt_exist/0]
      assert diagnostic.position == {0, 0}
    end

    test "reports unused variables", %{project: project} do
      source = ~S[
        defmodule WithWarnings do
          def error do
            unused = 3
          end
        end
      ]
      compile_source_file(project, source)

      assert_receive file_compiled(status: :success, diagnostics: [%Diagnostic{} = diagnostic])

      assert diagnostic.severity == :warning
      assert diagnostic.position == {3, 0}
      assert diagnostic.message =~ ~S[warning: variable "unused" is unused]
      assert diagnostic.details == {WithWarnings, :error, 0}
    end

    test "reports missing parens", %{project: project} do
      source = ~S[
        defmodule WithWarnings do
          def error do
            calc
          end

          defp calc do
            3
          end
        end
      ]
      compile_source_file(project, source)
      assert_receive file_compiled(status: :success, diagnostics: [%Diagnostic{} = diagnostic])

      assert diagnostic.severity == :warning
      assert diagnostic.position == {3, 0}

      assert diagnostic.message =~
               ~S[warning: variable "calc" does not exist and is being expanded to "calc()"]

      assert diagnostic.details == {WithWarnings, :error, 0}
    end

    test "reports unused defp functions", %{project: project} do
      source = ~S[
        defmodule UnusedDefp do
          defp unused do
          end
        end
      ]
      compile_source_file(project, source)

      assert_receive file_compiled(status: :success, diagnostics: [%Diagnostic{} = diagnostic])
      assert diagnostic.severity == :warning
      assert diagnostic.position == {2, 0}
      assert diagnostic.message =~ ~S[warning: function unused/0 is unused]
      assert diagnostic.details == nil
    end

    test "handles undefined usages", %{project: project} do
      source = ~S[
        defmodule WithUndefinedFunction do
          def error do
            unknown_fn()
          end
        end
      ]
      compile_source_file(project, source)

      assert_receive file_compiled(status: :error, diagnostics: [diagnostic])
      assert diagnostic.severity == :error
      assert diagnostic.position == {3, 0}
      assert diagnostic.message =~ ~S[undefined function unknown_fn/0]
      assert diagnostic.details == nil
    end

    test "adding a new module notifies the listener", %{project: project} do
      source = ~S[
      defmodule NewModule do
      end
      ]

      compile_source_file(project, source)
      assert_receive module_updated(name: NewModule, functions: [])
    end

    test "adding a function notifies the listener", %{project: project} do
      source = ~S[
        defmodule UnderTest do
          def added_function(a, b) do
            a + b
          end
        end
      ]

      compile_source_file(project, source)
      assert_receive module_updated(name: UnderTest, functions: [added_function: 2])
    end

    test "removing a function notifies the listener", %{project: project} do
      initial = ~S[
      defmodule Remove do
        def remove_me do
        end
      end
      ]

      removed = ~S[
        defmodule Remove do
        end
      ]

      compile_source_file(project, initial)
      assert_receive module_updated()

      compile_source_file(project, removed)
      assert_receive module_updated(name: Remove, functions: [])
    end

    test "changing a function's arity notifies the listener", %{project: project} do
      initial = ~S[
        defmodule ArityChange do
          def arity(_) do
          end
        end
      ]
      compile_source_file(project, initial)
      assert_receive module_updated(name: ArityChange, functions: [arity: 1])

      changed = ~S[
        defmodule ArityChange do
          def arity(_, _) do
          end
        end
      ]
      compile_source_file(project, changed)
      assert_receive module_updated(name: ArityChange, functions: [arity: 2])
    end

    test "adding a macro notifies the listener", %{project: project} do
      changed = ~S[
       defmodule UnderTest do
        defmacro something(a) do
          quote do
            a + 1
          end
        end
       end
      ]
      compile_source_file(project, changed)
      assert_receive module_updated(name: UnderTest, macros: [something: 1])
    end

    test "removing a macro notifies the listener", %{project: project} do
      initial = ~S[
      defmodule RemoveMacro do
        defmacro remove_me do
        end
      end
      ]

      removed = ~S[
        defmodule RemoveMacro do
        end
      ]

      compile_source_file(project, initial)
      assert_receive module_updated()

      compile_source_file(project, removed)
      assert_receive module_updated(name: RemoveMacro, macros: [])
    end

    test "changing a macro's arity notifies the listener", %{project: project} do
      initial = ~S[
        defmodule ArityChange do
          defmacro arity(_) do
          end
        end
      ]
      compile_source_file(project, initial)
      assert_receive module_updated(name: ArityChange, macros: [arity: 1])

      changed = ~S[
        defmodule ArityChange do
          defmacro arity(_, _) do
          end
        end
      ]
      compile_source_file(project, changed)
      assert_receive module_updated(name: ArityChange, macros: [arity: 2])
    end
  end
end