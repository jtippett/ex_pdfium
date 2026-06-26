defmodule ExPdfium.Text do
  @moduledoc """
  Repair extracted text degraded by legacy font encodings, recovering canonical
  Unicode. This is a deliberate, explicit layer *over* the raw text the NIF
  returns — `extract_text/2` is never silently changed.

  > This is font-encoding canonicalization, **not** Unicode Normalization. For
  > NFC/NFKC (ligatures, presentation forms), pipe through `String.normalize/2`.

  ## Regimes

  A regime names a text-encoding pathology and (when recoverable) its repair.
  Phase 1 ships one: `:thai_pua` (see `ExPdfium.Text.Repair.ThaiPua`).

      {text, report} = ExPdfium.Text.repair(raw)              # :auto
      {text, report} = ExPdfium.Text.repair(raw, regimes: [:thai_pua])
      regimes        = ExPdfium.Text.detect(raw)
  """

  # Internal registry. Append modules here as scripts are added; extract into a
  # behaviour only when a third regime justifies it (YAGNI).
  @regimes [ExPdfium.Text.Repair.ThaiPua]

  @type report :: %{applied: [map()], flagged: [map()]}

  @doc "Detect (don't transform) which regimes apply. Returns one entry per firing regime."
  @spec detect(binary()) :: [map()]
  def detect(text) when is_binary(text) do
    for r <- @regimes, {true, evidence} <- [detect_one(r, text)] do
      %{
        regime: r.id(),
        repairable?: r.kind() != :unrecoverable,
        evidence: evidence,
        source: r.source()
      }
    end
  end

  @doc "Repair `text`. `:regimes` is `:auto` (default) or a list of regime ids."
  @spec repair(binary(), keyword()) :: {binary(), report()}
  def repair(text, opts \\ []) when is_binary(text) do
    regimes = resolve(Keyword.get(opts, :regimes, :auto))

    {out, report} =
      Enum.reduce(regimes, {text, %{applied: [], flagged: []}}, fn r, {t, rep} ->
        case r.detect(t) do
          {false, _} ->
            {t, rep}

          {true, evidence} ->
            if r.kind() == :unrecoverable do
              {t, update(rep, :flagged, %{regime: r.id(), recommend: :ocr, evidence: evidence})}
            else
              {t2, n} = r.apply(t)
              {t2, update(rep, :applied, %{regime: r.id(), substitutions: n, source: r.source()})}
            end
        end
      end)

    {out, %{applied: Enum.reverse(report.applied), flagged: Enum.reverse(report.flagged)}}
  end

  # A regime only "fires" for detect/1 when evidence is non-zero.
  defp detect_one(regime, text) do
    case regime.detect(text) do
      {true, ev} when ev > 0 -> {true, ev}
      _ -> {false, 0}
    end
  end

  defp resolve(:auto), do: @regimes

  defp resolve(ids) when is_list(ids) do
    known = Map.new(@regimes, &{&1.id(), &1})

    Enum.map(ids, fn id ->
      Map.get(known, id) || raise ArgumentError, "unknown regime: #{inspect(id)}"
    end)
  end

  defp update(report, key, entry), do: Map.update!(report, key, &[entry | &1])
end
