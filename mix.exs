defmodule ExPdfium.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jtippett/ex_pdfium"

  def project do
    [
      app: :ex_pdfium,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      name: "ExPdfium",
      description:
        "Elixir NIF wrapper for pdfium — Google's Chromium PDF engine — via the Rust pdfium-render crate, shipped as a precompiled binary",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:rustler, "~> 0.38", optional: true},
      {:rustler_precompiled, "~> 0.8"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # Ship the Rust sources so a from-source build (rustler_precompiled
      # force_build / unsupported targets) works for consumers.
      files:
        ~w(lib native/ex_pdfium/Cargo.toml native/ex_pdfium/Cargo.lock native/ex_pdfium/src
           checksum-Elixir.ExPdfium.Native.exs .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end
end
