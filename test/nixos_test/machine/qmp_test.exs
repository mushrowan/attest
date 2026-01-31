defmodule NixosTest.Machine.QMPTest do
  use ExUnit.Case, async: true

  alias NixosTest.Machine.QMP

  describe "parse_message/1" do
    test "parses QMP greeting" do
      greeting =
        ~s({"QMP": {"version": {"qemu": {"micro": 0, "minor": 2, "major": 8}}, "capabilities": ["oob"]}})

      assert {:greeting, version} = QMP.parse_message(greeting)
      assert version["qemu"]["major"] == 8
    end

    test "parses success response" do
      response = ~s({"return": {}})
      assert {:ok, %{}} = QMP.parse_message(response)
    end

    test "parses success response with data" do
      response = ~s({"return": {"status": "running"}})
      assert {:ok, %{"status" => "running"}} = QMP.parse_message(response)
    end

    test "parses error response" do
      response = ~s({"error": {"class": "GenericError", "desc": "something went wrong"}})
      assert {:error, error} = QMP.parse_message(response)
      assert error.class == "GenericError"
      assert error.desc == "something went wrong"
    end

    test "parses event" do
      event = ~s({"event": "STOP", "timestamp": {"seconds": 1234, "microseconds": 0}})
      assert {:event, "STOP", _timestamp} = QMP.parse_message(event)
    end
  end

  describe "encode_command/2" do
    test "encodes simple command" do
      assert QMP.encode_command("qmp_capabilities") == ~s({"execute":"qmp_capabilities"}\n)
    end

    test "encodes command with arguments" do
      json = QMP.encode_command("screendump", %{"filename" => "/tmp/shot.ppm"})
      decoded = Jason.decode!(json)
      assert decoded["execute"] == "screendump"
      assert decoded["arguments"]["filename"] == "/tmp/shot.ppm"
    end

    test "encodes command with empty arguments" do
      json = QMP.encode_command("query-status", %{})
      decoded = Jason.decode!(json)
      assert decoded["execute"] == "query-status"
      refute Map.has_key?(decoded, "arguments")
    end
  end
end
