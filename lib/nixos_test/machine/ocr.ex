defmodule NixosTest.Machine.OCR do
  @moduledoc """
  OCR (optical character recognition) for VM screenshots

  Uses tesseract for text extraction and imagemagick for preprocessing.
  The python test driver runs three OCR passes in parallel: raw image,
  preprocessed positive, and preprocessed negative. we replicate that
  with Task.async_stream.
  """

  require Logger

  @doc """
  Run tesseract OCR on an image file

  ## Options

  - `:tesseract` — path to tesseract binary (default: "tesseract")
  """
  @spec run_tesseract(Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run_tesseract(image_path, opts \\ []) do
    bin = Keyword.get(opts, :tesseract, "tesseract")

    case System.find_executable(bin) do
      nil ->
        {:error, :not_found}

      tesseract ->
        # OEM 2 = legacy + LSTM, PSM 11 = sparse text
        args = [image_path, "-", "--oem", "2", "-c", "debug_file=/dev/null", "--psm", "11"]

        case System.cmd(tesseract, args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, code} -> {:error, {:tesseract_failed, code, output}}
        end
    end
  end

  @doc """
  Preprocess a screenshot with imagemagick for better OCR results

  ## Options

  - `:negate` — invert colours (default: false)
  - `:magick` — path to magick binary (default: "magick")
  """
  @spec preprocess(Path.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def preprocess(image_path, opts \\ []) do
    negate = Keyword.get(opts, :negate, false)
    bin = Keyword.get(opts, :magick, "magick")

    case System.find_executable(bin) do
      nil ->
        {:error, :not_found}

      magick ->
        stem = image_path |> Path.rootname() |> Path.basename()
        dir = Path.dirname(image_path)
        suffix = if negate, do: "negative", else: "positive"
        out_path = Path.join(dir, "#{stem}.#{suffix}.png")

        magick_args =
          [
            "convert",
            "-filter",
            "Catrom",
            "-density",
            "72",
            "-resample",
            "300",
            "-contrast",
            "-normalize",
            "-despeckle",
            "-type",
            "grayscale",
            "-sharpen",
            "1",
            "-posterize",
            "3"
          ] ++
            if(negate, do: ["-negate"], else: []) ++
            ["-gamma", "100", "-blur", "1x65535", image_path, out_path]

        case System.cmd(magick, magick_args, stderr_to_stdout: true) do
          {_output, 0} -> {:ok, out_path}
          {output, code} -> {:error, {:magick_failed, code, output}}
        end
    end
  end

  @doc """
  Perform OCR on a screenshot, returning extracted text
  """
  @spec perform_ocr(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def perform_ocr(screenshot_path) do
    run_tesseract(screenshot_path)
  end

  @doc """
  Perform OCR with preprocessed variants for better detection

  Returns a list of three text strings: raw, positive, and negative.
  Runs all three in parallel.
  """
  @spec perform_ocr_variants(Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def perform_ocr_variants(screenshot_path) do
    tasks = [
      Task.async(fn -> run_tesseract(screenshot_path) end),
      Task.async(fn -> preprocess_and_ocr(screenshot_path, false) end),
      Task.async(fn -> preprocess_and_ocr(screenshot_path, true) end)
    ]

    results = Task.await_many(tasks, 30_000)

    texts =
      Enum.map(results, fn
        {:ok, text} -> text
        {:error, _} -> ""
      end)

    {:ok, texts}
  end

  defp preprocess_and_ocr(screenshot_path, negate) do
    with {:ok, processed_path} <- preprocess(screenshot_path, negate: negate),
         {:ok, text} <- run_tesseract(processed_path) do
      {:ok, text}
    end
  end
end
