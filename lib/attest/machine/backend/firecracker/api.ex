defmodule Attest.Machine.Backend.Firecracker.API do
  @moduledoc """
  Minimal HTTP/1.1 client for the firecracker REST API over unix domain socket

  Firecracker exposes its API on an AF_UNIX socket. This module sends
  JSON requests and parses responses without any external HTTP deps.
  """

  require Logger

  @doc """
  Send a PUT request with a JSON body
  """
  @spec put(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put(socket_path, path, body) do
    request(socket_path, "PUT", path, Jason.encode!(body))
  end

  @doc """
  Send a PUT request with no body (for endpoints that don't accept one)
  """
  @spec put_no_body(String.t(), String.t()) :: :ok | {:error, term()}
  def put_no_body(socket_path, path) do
    request(socket_path, "PUT", path, nil)
  end

  @doc """
  Send a PATCH request with a JSON body
  """
  @spec patch(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def patch(socket_path, path, body) do
    request(socket_path, "PATCH", path, Jason.encode!(body))
  end

  @doc """
  Send a GET request and return the parsed JSON response
  """
  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(socket_path, path) do
    request(socket_path, "GET", path, nil)
  end

  defp request(socket_path, method, path, body) do
    with {:ok, socket} <- connect(socket_path),
         :ok <- send_request(socket, method, path, body),
         {:ok, status, response_body} <- recv_response(socket) do
      :gen_tcp.close(socket)
      handle_response(method, status, response_body)
    end
  end

  defp connect(socket_path) do
    :gen_tcp.connect({:local, socket_path}, 0, [:binary, {:active, false}], 5000)
  end

  defp send_request(socket, method, path, nil) do
    request = "#{method} #{path} HTTP/1.1\r\nHost: localhost\r\n\r\n"
    :gen_tcp.send(socket, request)
  end

  defp send_request(socket, method, path, body) do
    request =
      "#{method} #{path} HTTP/1.1\r\n" <>
        "Host: localhost\r\n" <>
        "Content-Type: application/json\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "\r\n" <>
        body

    :gen_tcp.send(socket, request)
  end

  defp recv_response(socket) do
    recv_response(socket, "")
  end

  defp recv_response(socket, acc) do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, data} ->
        acc = acc <> data

        case parse_http_response(acc) do
          {:complete, status, body} -> {:ok, status, body}
          :incomplete -> recv_response(socket, acc)
        end

      {:error, :closed} ->
        # server closed connection, try to parse what we have
        case parse_http_response(acc) do
          {:complete, status, body} -> {:ok, status, body}
          :incomplete -> {:error, :incomplete_response}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_http_response(data) do
    case String.split(data, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        status = parse_status(headers)
        content_length = parse_content_length(headers)

        if byte_size(body) >= content_length do
          {:complete, status, String.slice(body, 0, content_length)}
        else
          :incomplete
        end

      _ ->
        :incomplete
    end
  end

  defp parse_status(headers) do
    case Regex.run(~r/HTTP\/1\.\d (\d+)/, headers) do
      [_, code] -> String.to_integer(code)
      _ -> 0
    end
  end

  defp parse_content_length(headers) do
    case Regex.run(~r/Content-Length:\s*(\d+)/i, headers) do
      [_, length] -> String.to_integer(length)
      _ -> 0
    end
  end

  defp handle_response("GET", 200, body) do
    {:ok, Jason.decode!(body)}
  end

  defp handle_response(_method, status, _body) when status in [200, 204] do
    :ok
  end

  defp handle_response(_method, status, body) when byte_size(body) > 0 do
    {:error, {status, Jason.decode!(body)}}
  end

  defp handle_response(_method, status, _body) do
    {:error, {status, %{}}}
  end
end
