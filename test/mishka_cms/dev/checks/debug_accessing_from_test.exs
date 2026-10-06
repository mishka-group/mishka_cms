defmodule MishkaCms.Dev.Checks.DebugAccessingFromTest do
  use ExUnit.Case, async: true

  alias MishkaCms.Dev.Checks.DebugAccessingFrom

  describe "describe/1" do
    test "returns a description string" do
      assert DebugAccessingFrom.describe([]) == "Debug: Print accessing_from context"
    end
  end

  describe "match?/3 with accessing_from" do
    test "returns true when accessing_from is present" do
      context = %{
        accessing_from: %{source: SomeResource, relationship: :versions}
      }

      assert capture_io(fn ->
               assert DebugAccessingFrom.match?(nil, context, []) == true
             end) =~ "accessing_from"
    end

    test "prints the source and relationship" do
      context = %{
        accessing_from: %{source: SomeResource, relationship: :my_relation}
      }

      output =
        capture_io(fn ->
          DebugAccessingFrom.match?(%{id: "user-1"}, context, [])
        end)

      assert output =~ "ACCESSING FROM DEBUG"
      assert output =~ "my_relation"
      assert output =~ "SomeResource"
    end

    test "always returns true regardless of actor" do
      context = %{accessing_from: %{source: SomeResource, relationship: :items}}

      capture_io(fn ->
        assert DebugAccessingFrom.match?(nil, context, []) == true
        assert DebugAccessingFrom.match?(%{id: "user-1"}, context, []) == true
        assert DebugAccessingFrom.match?("any_actor", context, []) == true
      end)
    end
  end

  describe "match?/3 without accessing_from" do
    test "returns true when no accessing_from key" do
      context = %{action: :read, resource: SomeResource}

      assert capture_io(fn ->
               assert DebugAccessingFrom.match?(nil, context, []) == true
             end) =~ "No accessing_from"
    end

    test "prints context info" do
      context = %{action: :read}

      output =
        capture_io(fn ->
          DebugAccessingFrom.match?(nil, context, [])
        end)

      assert output =~ "No accessing_from"
      assert output =~ "Context"
    end

    test "returns true for empty context" do
      assert capture_io(fn ->
               assert DebugAccessingFrom.match?(nil, %{}, []) == true
             end) =~ "No accessing_from"
    end
  end

  defp capture_io(fun) do
    ExUnit.CaptureIO.capture_io(fun)
  end
end
