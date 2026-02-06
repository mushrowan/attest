defmodule NixosTest.Machine.Backend.Firecracker.APITest do
  use ExUnit.Case, async: true

  alias NixosTest.Machine.Backend.Firecracker.API

  # helper: mock HTTP server on a UDS
  defp with_mock_api(handler, fun) do
    socket_path =
      Path.join(System.tmp_dir!(), "fc-api-#{:rand.uniform(100_000)}.sock")

    File.rm(socket_path)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        {:active, false},
        {:ip, {:local, socket_path}},
        {:reuseaddr, true}
      ])

    pid =
      spawn(fn ->
        accept_loop(listen, handler)
      end)

    try do
      fun.(socket_path)
    after
      Process.exit(pid, :kill)
      :gen_tcp.close(listen)
      File.rm(socket_path)
    end
  end

  defp accept_loop(listen, handler) do
    case :gen_tcp.accept(listen, 5000) do
      {:ok, client} ->
        {:ok, request} = recv_http_request(client)
        response = handler.(request)
        :ok = :gen_tcp.send(client, response)
        :gen_tcp.close(client)
        accept_loop(listen, handler)

      {:error, :timeout} ->
        :ok
    end
  end

  defp recv_http_request(socket) do
    recv_http_request(socket, "")
  end

  defp recv_http_request(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, data} ->
        acc = acc <> data

        if String.contains?(acc, "\r\n\r\n") do
          # check for content-length to read body
          case Regex.run(~r/Content-Length: (\d+)/i, acc) do
            [_, length_str] ->
              content_length = String.to_integer(length_str)
              [headers, body_start] = String.split(acc, "\r\n\r\n", parts: 2)
              remaining = content_length - byte_size(body_start)

              if remaining > 0 do
                {:ok, rest} = :gen_tcp.recv(socket, remaining, 5000)
                {:ok, headers <> "\r\n\r\n" <> body_start <> rest}
              else
                {:ok, acc}
              end

            nil ->
              {:ok, acc}
          end
        else
          recv_http_request(socket, acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  describe "put/3" do
    test "sends PUT request and parses 204 response" do
      with_mock_api(
        fn request ->
          assert request =~ "PUT /boot-source HTTP/1.1"
          assert request =~ "kernel_image_path"
          "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"
        end,
        fn socket_path ->
          body = %{"kernel_image_path" => "/path/to/vmlinux", "boot_args" => "console=ttyS0"}
          assert :ok = API.put(socket_path, "/boot-source", body)
        end
      )
    end

    test "returns error body on 400 response" do
      with_mock_api(
        fn _request ->
          body = Jason.encode!(%{"fault_message" => "Invalid config"})

          "HTTP/1.1 400 Bad Request\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"
        end,
        fn socket_path ->
          assert {:error, {400, %{"fault_message" => "Invalid config"}}} =
                   API.put(socket_path, "/machine-config", %{"vcpu_count" => -1})
        end
      )
    end
  end

  describe "get/2" do
    test "sends GET request and returns parsed JSON body" do
      with_mock_api(
        fn request ->
          assert request =~ "GET / HTTP/1.1"
          body = Jason.encode!(%{"state" => "Running", "vmm_version" => "1.15.0"})
          "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"
        end,
        fn socket_path ->
          assert {:ok, %{"state" => "Running"}} = API.get(socket_path, "/")
        end
      )
    end
  end

  describe "patch/3" do
    test "sends PATCH request" do
      with_mock_api(
        fn request ->
          assert request =~ "PATCH /vm HTTP/1.1"
          assert request =~ "Paused"
          "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"
        end,
        fn socket_path ->
          assert :ok = API.patch(socket_path, "/vm", %{"state" => "Paused"})
        end
      )
    end
  end
end
