defmodule ExPdfium.ReleaseInvariantsTest do
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)
  @targets ~w(
    aarch64-apple-darwin
    aarch64-unknown-linux-gnu
    x86_64-apple-darwin
    x86_64-unknown-linux-gnu
  )

  test "checked-in precompiled checksums match every supported target and current version" do
    version = Mix.Project.config()[:version]

    {checksums, _binding} =
      Code.eval_file(Path.join(@root, "checksum-Elixir.ExPdfium.Native.exs"))

    expected =
      MapSet.new(@targets, fn target ->
        "libex_pdfium-v#{version}-nif-2.15-#{target}.so.tar.gz"
      end)

    assert MapSet.new(Map.keys(checksums)) == expected

    assert Enum.all?(checksums, fn {_artifact, digest} ->
             String.match?(digest, ~r/^sha256:[0-9a-f]{64}$/)
           end)
  end

  test "the pinned pdfium assets have complete digests used by CI and release builds" do
    sums = File.read!(Path.join(@root, "PDFIUM_SHA256SUMS"))

    assets =
      for line <- String.split(sums, "\n"),
          not String.starts_with?(line, "#"),
          line != "",
          into: %{} do
        [digest, asset] = String.split(line)
        {asset, digest}
      end

    assert Map.keys(assets) |> Enum.sort() ==
             ~w(pdfium-linux-arm64.tgz pdfium-linux-x64.tgz pdfium-mac-arm64.tgz pdfium-mac-x64.tgz)

    assert Enum.all?(assets, fn {_asset, digest} ->
             String.match?(digest, ~r/^[0-9a-f]{64}$/)
           end)

    for file <- [".github/workflows/ci.yml", ".github/workflows/release.yml"] do
      workflow = File.read!(Path.join(@root, file))
      assert workflow =~ ~s(PDFIUM_TAG: "chromium/7543")
      assert workflow =~ "PDFIUM_SHA256SUMS"
      assert workflow =~ "shasum -a 256"

      action_refs =
        Regex.scan(~r/uses:\s+[^@\s]+@([^\s]+)/, workflow, capture: :all_but_first)
        |> List.flatten()

      assert action_refs != []
      assert Enum.all?(action_refs, &String.match?(&1, ~r/^[0-9a-f]{40}$/))
    end
  end

  test "native exports, stubs, scheduler classes, ABI, and dependency features stay aligned" do
    rust = File.read!(Path.join(@root, "native/ex_pdfium/src/lib.rs"))

    rust_exports =
      ~r/#\[rustler::nif[^\]]*\]\s*(?:#\[[^\]]*\]\s*)?fn\s+([a-z_]+)/
      |> Regex.scan(rust, capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()

    stub_exports =
      ExPdfium.Native.__info__(:functions)
      |> Enum.reject(fn {name, _arity} -> name == :rustler_init end)
      |> Enum.map(fn {name, _arity} -> Atom.to_string(name) end)
      |> MapSet.new()

    assert MapSet.size(rust_exports) == 45
    assert rust_exports == stub_exports
    assert length(Regex.scan(~r/#\[rustler::nif\(schedule = "DirtyCpu"\)\]/, rust)) == 45

    native = File.read!(Path.join(@root, "lib/ex_pdfium/native.ex"))
    release = File.read!(Path.join(@root, ".github/workflows/release.yml"))
    cargo = File.read!(Path.join(@root, "native/ex_pdfium/Cargo.toml"))

    for target <- @targets do
      assert native =~ target
      assert release =~ target
    end

    assert release =~ "nif-2.15"
    assert cargo =~ ~s(rustler = "0.38")
    assert cargo =~ ~s(default = ["sync"])
    assert cargo =~ ~s(version = "=0.8.37")
    assert cargo =~ ~s(features = ["pdfium_latest"])
  end
end
