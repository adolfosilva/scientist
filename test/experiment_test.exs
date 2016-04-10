defmodule ExperimentTest do
  use ExUnit.Case

  alias Scientist.Experiment
  alias Scientist.Observation
  alias Scientist.Result

  test "it has a default name" do
    assert Experiment.new.name == "Elixir.Scientist.Experiment"
  end

  test "it accepts a context" do
    experiment = Experiment.new("Some experiment", context: %{foo: "bar"})
    assert experiment.context == %{foo: "bar"}
  end

  test "it can't be run without a control" do
    experiment = Experiment.new
    assert_raise(ArgumentError, fn -> Experiment.run(experiment) end)
  end

  test "it only can have a single control" do
    fun = fn ->
      Experiment.new
      |> Experiment.add_control(fn -> :control end)
      |> Experiment.add_control(fn -> :second_control end)
    end
    assert_raise(ArgumentError, fun)
  end

  test "it passes through the control" do
    assert :control ==
      Experiment.new
      |> Experiment.add_control(fn -> :control end)
      |> Experiment.run
  end

  test "it runs every candidate" do
    parent = self
    Experiment.new
      |> Experiment.add_control(fn -> send(parent, 1) end)
      |> Experiment.add_observable("one", fn -> send(parent, 2) end)
      |> Experiment.add_observable("two", fn -> send(parent, 3) end)
      |> Experiment.run
    assert_received 1
    assert_received 2
    assert_received 3
  end

  test "it runs the candidates in arbitrary order" do
    parent = self
    experiment = Experiment.new
      |> Experiment.add_control(fn -> send(parent, 1) end)
      |> Experiment.add_observable("one", fn -> send(parent, 2) end)

    Stream.repeatedly(fn -> Experiment.run(experiment) end)
    |> Stream.take(1000)
    |> Enum.to_list
    {_, messages} = Process.info(self, :messages)

    unique = Enum.chunk(messages, 2) |> Enum.uniq |> Enum.count
    assert unique == 2
  end

  test "it compares results" do
    matched = Experiment.new
    |> Experiment.add_control(fn -> 1 end)
    |> Experiment.add_observable("candidate", fn -> 1 end)
    |> Experiment.run(result: true)
    |> Scientist.Result.matched?

    assert matched
  end

  test "it compares with the comparator provided" do
    matched = Experiment.new
    |> Experiment.add_control(fn -> :control end)
    |> Experiment.add_observable("candidate", fn -> "control" end)
    |> Experiment.compare_with(fn(co, ca) -> Atom.to_string(co) == ca end)
    |> Experiment.run(result: true)
    |> Scientist.Result.matched?

    assert matched
  end

  defmodule TestExperiment do
    use Scientist.Experiment

    def name, do: "My awesome experiment"

    def default_context, do: %{foo: :foo}

    def enabled?, do: true
    def publish(result) do
      context = result.experiment.context
      send(context.parent, :published)
    end

    def raised(experiment, operation, except) do
      # Send a message with the exception to the parent process
      parent = experiment.context[:parent]
      send(parent, {operation, except})
    end

    def thrown(experiment, operation, except) do
      parent = experiment.context[:parent]
      send(parent, {:thrown, operation, except})
    end
  end

  test "it uses the default context" do
    assert TestExperiment.new.context == %{foo: :foo}

    assert TestExperiment.new("test", context: %{foo: :bar}).context == %{foo: :bar}

    custom_context = %{bar: :bar}
    assert TestExperiment.new("test", context: custom_context).context == %{foo: :foo, bar: :bar}

  end

  test "it uses the default name" do
    assert TestExperiment.new.name == "My awesome experiment"
  end

  test "it reports errors raised during compare" do
    experiment = TestExperiment.new("test", context: %{parent: self})
    |> Experiment.add_control(fn -> :control end)
    |> Experiment.add_observable("candidate", fn -> :control end)

    experiment
    |> Experiment.compare_with(fn _, _ -> raise "SCARY ERROR" end)
    |> Experiment.run(result: true)

    assert_received {:compare, %RuntimeError{message: "SCARY ERROR"}}

    experiment
    |> Experiment.compare_with(fn _, _ -> throw "SCARY ERROR" end)
    |> Experiment.run(result: true)

    assert_received {:thrown, :compare, "SCARY ERROR"}
  end

  test "it reports errors raised during clean" do
    experiment = TestExperiment.new("test", context: %{parent: self})
    |> Experiment.add_control(fn -> :control end)
    |> Experiment.add_observable("candidate", fn -> :control end)

    experiment
    |> Experiment.clean_with(fn _ -> raise "YOU GOT SPOOKED" end)
    |> Experiment.run(result: true)

    assert_received {:clean, %RuntimeError{message: "YOU GOT SPOOKED"}}

    experiment
    |> Experiment.clean_with(fn _ -> throw "YOU GOT SPOOKED" end)
    |> Experiment.run(result: true)

    assert_received {:thrown, :clean, "YOU GOT SPOOKED"}
  end

  test "it uses the publish function during run" do
    TestExperiment.new("test", context: %{parent: self})
    |> Experiment.add_control(fn -> :control end)
    |> Experiment.add_observable("candidate", fn -> :control end)
    |> Experiment.run(result: true)

    assert_received :published
  end

  defmodule BadPublishExperiment do
    use Scientist.Experiment

    def enabled?, do: true
    def publish(_), do: raise "ka-BOOM"

    def raised(experiment, operation, except) do
      # Send a message with the exception to the parent process
      parent = experiment.context[:parent]
      send(parent, {operation, except})
    end
  end

  test "it reports errors raised during publish" do
    BadPublishExperiment.new("test", context: %{parent: self})
    |> Experiment.add_control(fn -> :control end)
    |> Experiment.add_observable("candidate", fn -> :control end)
    |> Experiment.run(result: true)

    assert_received {:publish, %RuntimeError{message: "ka-BOOM"}}
  end

  defmodule NotEnabledExperiment do
    use Scientist.Experiment

    def enabled?, do: false
    def publish(result) do
      parent = result.experiment.context[:parent]
      send(parent, :published)
    end
  end

  test "it does not run when enabled? returns false" do
    NotEnabledExperiment.new("test")
    |> Experiment.add_control(fn -> :control end)
    |> Experiment.add_observable("candidate", fn -> :control end)
    |> Experiment.run(result: true)

    refute_received :published
  end

  defmodule BadEnabledExperiment do
    use Scientist.Experiment

    def enabled?, do: raise "WHOA"
    def publish(_), do: :ok

    def raised(experiment, operation, except) do
      # Send a message with the exception to the parent process
      parent = experiment.context[:parent]
      send(parent, {operation, except})
    end
  end

  test "it reports errors raised in enabled?" do
    BadEnabledExperiment.new("test", context: %{parent: self})
    |> Experiment.add_control(fn -> :control end)
    |> Experiment.add_observable("candidate", fn -> :control end)
    |> Experiment.run

    assert_received {:enabled, %RuntimeError{message: "WHOA"}}
  end

  test "it runs when run_if returns true" do
    TestExperiment.new("test", context: %{parent: self})
    |> Experiment.add_control(fn -> :control end)
    |> Experiment.add_observable("candidate", fn -> :control end)
    |> Experiment.set_run_if(fn -> true end)
    |> Experiment.run

    assert_received :published
  end

  test "it does not run when run_if returns false" do
    TestExperiment.new("test", context: %{parent: self})
    |> Experiment.add_control(fn -> :control end)
    |> Experiment.add_observable("candidate", fn -> :control end)
    |> Experiment.set_run_if(fn -> false end)
    |> Experiment.run

    refute_received :published
  end

  test "it reports errors raised in run_if" do
    TestExperiment.new("test", context: %{parent: self})
    |> Experiment.add_control(fn -> :control end)
    |> Experiment.add_observable("candidate", fn -> :control end)
    |> Experiment.set_run_if(fn -> raise "WHOA" end)
    |> Experiment.run

    assert_received {:run_if, %RuntimeError{message: "WHOA"}}
  end

  test "it uses the before_run function when run" do
    TestExperiment.new("test", context: %{parent: self})
    |> Experiment.add_control(fn -> :control end)
    |> Experiment.add_observable("candidate", fn -> :control end)
    |> Experiment.set_before_run(fn -> send(self, "hi") end)
    |> Experiment.run

    assert_received "hi"
  end

  test "it ignores the before_run function when it isn't run" do
    TestExperiment.new("test", context: %{parent: self})
    |> Experiment.add_control(fn -> :control end)
    |> Experiment.add_observable("candidate", fn -> :control end)
    |> Experiment.set_before_run(fn -> send(self, "hi") end)
    |> Experiment.set_run_if(fn -> false end)
    |> Experiment.run

    refute_received "hi"

    NotEnabledExperiment.new("test", context: %{parent: self})
    |> Experiment.add_control(fn -> :control end)
    |> Experiment.add_observable("candidate", fn -> :control end)
    |> Experiment.run

    refute_received "hi"
  end

  test "it does not ignore observations by default" do
    ex = Experiment.new
    obs_a = Observation.new(ex, "control", fn -> 1 end)
    obs_b = Observation.new(ex, "candidate", fn -> 2 end)

    refute Experiment.should_ignore_mismatch?(ex, obs_a, obs_b)
  end

  test "it reports mismatches as ignored when an ignored fn returns true" do
    ex = Experiment.new |> Experiment.ignore(fn _, _ -> true end)
    obs_a = Observation.new(ex, "control", fn -> 1 end)
    obs_b = Observation.new(ex, "candidate", fn -> 2 end)

    assert Experiment.should_ignore_mismatch?(ex, obs_a, obs_b)
  end

  test "it only calls its ignore functions if there is a mismatch" do
    Experiment.new
    |> Experiment.add_control(fn -> 1 end)
    |> Experiment.add_observable("candidate", fn -> 1 end)
    |> Experiment.ignore(fn _, _ -> send(self, :ignore); false end)
    |> Experiment.run

    refute_received :ignore
  end

  test "it attempts every ignore function passed in" do
    Experiment.new
    |> Experiment.add_control(fn -> 1 end)
    |> Experiment.add_observable("candidate", fn -> 2 end)
    |> Experiment.ignore(fn _, _ -> send(self, :ignore_one); false end)
    |> Experiment.ignore(fn _, _ -> send(self, :ignore_two); false end)
    |> Experiment.run

    assert_received :ignore_one
    assert_received :ignore_two
  end

  test "it only attempts until a single ignore function returns true" do
    Experiment.new
    |> Experiment.add_control(fn -> 1 end)
    |> Experiment.add_observable("candidate", fn -> 2 end)
    |> Experiment.ignore(fn _, _ -> send(self, :ignore_one); true end)
    |> Experiment.ignore(fn _, _ -> send(self, :ignore_two); false end)
    |> Experiment.run

    assert_received :ignore_one
    refute_received :ignore_two
  end

  test "it reports errors raised in an ignore fn" do
    TestExperiment.new("test", context: %{parent: self})
    |> Experiment.add_control(fn -> 1 end)
    |> Experiment.add_observable("candidate", fn -> 2 end)
    |> Experiment.ignore(fn _, _ -> raise "foo" end)
    |> Experiment.run

    assert_received {:ignore, %RuntimeError{message: "foo"}}
  end

  test "it skips ignore blocks that raise an exception" do
    did_ignore = TestExperiment.new("test", context: %{parent: self})
    |> Experiment.add_control(fn -> 1 end)
    |> Experiment.add_observable("candidate", fn -> 2 end)
    |> Experiment.ignore(fn _, _ -> raise "foo" end)
    |> Experiment.ignore(fn _, _ -> send(self, :ignore_two); true end)
    |> Experiment.run(result: true)
    |> Result.ignored?

    assert did_ignore
    assert_received :ignore_two
  end
end
