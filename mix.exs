defmodule ExPdfium.MixProject do
  use Mix.Project

  # Do not hand-edit. The release script (`scripts/release.exs`, via `just
  # release`) bumps this line and the CHANGELOG together; editing it by hand
  # desyncs the two and the precompiled-NIF release dance (see UPDATE_PROCEDURE.md).
  @version "0.4.3"
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
      {:vix, "~> 0.39", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["James Tippett"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
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
      source_ref: "v#{@version}",
      # Group the API by capability so the sidebar mirrors the README sections.
      # Functions are tagged with `@doc group:` in lib/ex_pdfium.ex.
      groups_for_docs: [
        Documents: &(&1[:group] == :documents),
        Rendering: &(&1[:group] == :rendering),
        "Text & search": &(&1[:group] == :text),
        "Metadata & geometry": &(&1[:group] == :metadata),
        "Structure & navigation": &(&1[:group] == :structure),
        "Forms & annotations": &(&1[:group] == :forms),
        "Images & objects": &(&1[:group] == :extraction),
        "Creating documents": &(&1[:group] == :creation),
        Annotating: &(&1[:group] == :annotations),
        "Writing (page assembly)": &(&1[:group] == :writing),
        Diagnostics: &(&1[:group] == :diagnostics)
      ]
    ]
  end
end
