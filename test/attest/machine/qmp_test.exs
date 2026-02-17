defmodule Attest.Machine.QMPTest do
  use ExUnit.Case, async: true

  alias Attest.Machine.QMP

  # helper to create a mock QMP server
  defp with_mock_qmp(responses, fun) do
    # create temp socket path
    socket_path = Path.join(System.tmp_dir!(), "qmp-test-#{:rand.uniform(100_000)}.sock")

    # ensure clean state
    File.rm(socket_path)

    # start listening
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        {:packet, :line},
        {:active, false},
        {:ip, {:local, socket_path}}
      ])

    # spawn mock server
    parent = self()

    server =
      spawn_link(fn ->
        {:ok, client} = :gen_tcp.accept(listen)
        # send greeting
        :ok =
          :gen_tcp.send(
            client,
            ~s({"QMP": {"version": {"qemu": {"major": 8}}, "capabilities": []}}\n)
          )

        # handle request/response pairs
        Enum.each(responses, fn response ->
          {:ok, _request} = :gen_tcp.recv(client, 0, 5000)
          :ok = :gen_tcp.send(client, response <> "\n")
        end)

        send(parent, :server_done)
        # keep alive until test ends
        receive do
          :stop -> :ok
        end
      end)

    try do
      fun.(socket_path)
    after
      send(server, :stop)
      :gen_tcp.close(listen)
      File.rm(socket_path)
    end
  end

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

  describe "connect/1" do
    test "connects and negotiates capabilities" do
      with_mock_qmp([~s({"return": {}})], fn socket_path ->
        {:ok, qmp} = QMP.start_link(socket_path: socket_path)
        assert Process.alive?(qmp)

        # wait for server to finish handshake
        assert_receive :server_done, 1000

        GenServer.stop(qmp)
      end)
    end
  end

  describe "command/3" do
    test "sends command and receives success response" do
      responses = [
        # qmp_capabilities response
        ~s({"return": {}}),
        # query-status response
        ~s({"return": {"status": "running", "singlestep": false}})
      ]

      with_mock_qmp(responses, fn socket_path ->
        {:ok, qmp} = QMP.start_link(socket_path: socket_path)

        assert {:ok, result} = QMP.command(qmp, "query-status")
        assert result["status"] == "running"

        GenServer.stop(qmp)
      end)
    end

    test "sends command with arguments" do
      responses = [
        ~s({"return": {}}),
        ~s({"return": {}})
      ]

      with_mock_qmp(responses, fn socket_path ->
        {:ok, qmp} = QMP.start_link(socket_path: socket_path)

        assert {:ok, %{}} = QMP.command(qmp, "screendump", %{"filename" => "/tmp/shot.ppm"})

        GenServer.stop(qmp)
      end)
    end

    test "returns error for failed command" do
      responses = [
        ~s({"return": {}}),
        ~s({"error": {"class": "GenericError", "desc": "file not found"}})
      ]

      with_mock_qmp(responses, fn socket_path ->
        {:ok, qmp} = QMP.start_link(socket_path: socket_path)

        assert {:error, error} = QMP.command(qmp, "screendump", %{"filename" => "/nonexistent"})
        assert error.class == "GenericError"
        assert error.desc == "file not found"

        GenServer.stop(qmp)
      end)
    end
  end
end
