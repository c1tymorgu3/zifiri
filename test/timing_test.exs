defmodule Zifiri.TimingTest do
  @moduledoc """
  `docs/scope-v5.md` §2, sessiz mod: bir kova boşaldığında 120 gövde **tek bir
  anda** çıkar ve sıra, gerçek yazının kaçıncı olduğunu söylememelidir.

  İki şey ölçülür:

    1. **Sıra rastgele mi** — aynı 120 mesaj aynı sırayla 10 kez kovaya konup
       boşaltılır; 10 boşaltmanın çoğu farklı permütasyon olmalı ve gerçek
       mesajın konumu her seferinde aynı yerde kalmamalı.
    2. **Konum tekdüze mi** — 1 gerçek + 119 decoy, 1000 kez boşaltılır; gerçek
       mesajın 0-tabanlı konumu 0..119 üzerinde tekdüze dağılmalı. Tekdüze
       dağılımın ortalaması 59.5, standart sapması `sqrt((n²-1)/12) = 34.64`.

  ## Eşikler ve gerekçeleri

  | ölçüm | beklenen | eşik | gerekçe |
  |---|---|---|---|
  | farklı permütasyon (10) | ~10 | ≥ 9 | 120! permütasyonda iki çakışma beklenmez |
  | ortalama konum | 59.5 | \\|x̄−59.5\\| < 6 | SE = 34.64/√1000 ≈ 1.10; 6 ≈ 5.4 SE |
  | standart sapma | 34.64 | 31 ≤ s ≤ 38 | s'nin SE'si ≈ 0.77; aralık ±4 SE |
  | ki-kare (12 bin, df=11) | 11 | < 31.26 | χ²(11, p=0.001) kritik değeri |
  | en boş bin | 83.3 | > 40 | bin sayımının SD'si ≈ 8.7; 40 ≈ 5σ altı |

  Görevdeki örnek eşik `|ortalama−60| < 12` idi; 12, SE'nin 11 katıdır ve
  belirgin biçimde yanlı bir karıştırıcıyı bile geçirirdi, bu yüzden 6'ya
  çekildi. Tohum sabit olduğu için bu test deterministik: aynı koşu, aynı
  sayılar; eşikler yine de ölçümün üstünde rahat bir payla duruyor.

  ## Determinizm ve yalıtım

  `:rand` süreç-yereldir; `setup` her test sürecinde tohumlar. `Zifiri.Bucket`
  ve `Zifiri.Chat.Decoy` süreçler arası tek ETS tablosu kullandığı için bu
  modül `async: false`.
  """

  use ExUnit.Case, async: false

  alias Zifiri.Bucket
  alias Zifiri.Chat.{Decoy, Message}

  @seed {20_261_122, 59, 120}
  @room "chat:lobby"
  @epoch :binary.copy(<<0xC3>>, 16)
  @total 120
  @trials 1000
  @bucket_ms 600_000
  @at 1_766_000_000_000 + div(@bucket_ms, 2)

  @expected_mean 59.5
  @expected_sd :math.sqrt((@total * @total - 1) / 12)

  setup do
    :rand.seed(:exsss, @seed)
    Bucket.reset()
    on_exit(fn -> Bucket.reset() end)

    real = real_message()
    decoys = Decoy.fill(@total, real: 1, epoch: @epoch, room: @room, at: @at)
    batch = [real | decoys]

    assert length(batch) == @total
    assert Enum.uniq_by(batch, & &1.id) |> length() == @total

    %{batch: batch}
  end

  test "aynı girdi 10 kez boşaltılınca sıra değişiyor", %{batch: batch} do
    ids = Enum.map(batch, & &1.id)

    orders =
      for _ <- 1..10 do
        fill(batch)
        %{items: items, size: size} = Bucket.drain()
        assert size == @total
        Enum.map(items, & &1.id)
      end

    # Her boşaltma girdinin tamamını, kayıpsız ve tekrarsız taşır.
    for order <- orders do
      assert Enum.sort(order) == Enum.sort(ids)
    end

    distinct_orders = orders |> Enum.uniq() |> length()
    positions = Enum.map(orders, fn order -> Enum.find_index(order, &(&1 == :real)) end)
    distinct_positions = positions |> Enum.uniq() |> length()

    IO.puts(
      "[timing] 10 boşaltma: #{distinct_orders} farklı permütasyon, " <>
        "#{distinct_positions} farklı gerçek-konum #{inspect(positions)}"
    )

    assert distinct_orders >= 9,
           "10 boşaltmada yalnız #{distinct_orders} farklı permütasyon"

    assert distinct_positions >= 7,
           "gerçek mesaj 10 boşaltmada yalnız #{distinct_positions} farklı konumda"

    # Hiçbiri giriş sırası değil: karıştırma gerçekten çalışıyor, "shuffle"
    # adı verilmiş bir `Enum.reverse/1` değil.
    refute Enum.any?(orders, &(&1 == ids))
  end

  test "gerçek mesajın konumu 0..119 üzerinde tekdüze (1000 örnek)", %{batch: batch} do
    positions =
      for _ <- 1..@trials do
        fill(batch)
        %{items: items, size: @total} = Bucket.drain()
        Enum.find_index(items, &(&1.id == :real))
      end

    assert length(positions) == @trials
    assert Enum.all?(positions, &(&1 >= 0 and &1 < @total))

    mean = Enum.sum(positions) / @trials
    sd = :math.sqrt(Enum.sum(Enum.map(positions, fn p -> (p - mean) ** 2 end)) / @trials)

    # 12 bin × 10 konum; her bin 0..119 aralığının onda biri.
    bins = Enum.frequencies_by(positions, &div(&1, 10))
    counts = for index <- 0..11, do: Map.get(bins, index, 0)
    expected = @trials / 12

    chi2 =
      counts
      |> Enum.map(fn count -> (count - expected) ** 2 / expected end)
      |> Enum.sum()

    critical = chi2_critical(11, 3.0902)

    IO.puts(
      "[timing] 1000 örnek: ortalama=#{Float.round(mean, 2)} " <>
        "(beklenen #{@expected_mean}), sd=#{Float.round(sd, 2)} " <>
        "(beklenen #{Float.round(@expected_sd, 2)})"
    )

    IO.puts(
      "[timing] ki-kare(12 bin, df=11)=#{Float.round(chi2, 2)}, " <>
        "kritik(p=0.001)=#{Float.round(critical, 2)}, bin sayımları=[#{Enum.join(counts, ", ")}]"
    )

    assert abs(mean - @expected_mean) < 6.0,
           "ortalama #{Float.round(mean, 2)}; beklenen #{@expected_mean} ± 6"

    assert sd > 31.0 and sd < 38.0,
           "standart sapma #{Float.round(sd, 2)}; beklenen #{Float.round(@expected_sd, 2)} (31..38)"

    assert chi2 < critical,
           "ki-kare #{Float.round(chi2, 2)} > kritik #{Float.round(critical, 2)}"

    assert Enum.min(counts) > 40,
           "en boş bin #{Enum.min(counts)}; beklenen ≈ #{Float.round(expected, 1)}"
  end

  test "boş kova boş döner, kayıp ve tekrar yok" do
    %{items: [], size: 0} = Bucket.drain()
    assert Bucket.size() == 0
  end

  ## Yardımcılar

  defp fill(batch) do
    Bucket.reset()
    Enum.each(batch, &Bucket.add/1)
    assert Bucket.size() == @total
  end

  # Tek gerçek mesaj: gerçek istemcinin imzaladığı 4 KB çerçeve. Kimliği
  # `:real`; decoy'ların kimliği tamsayı. Bu etiket yalnızca testin kendi
  # ölçümü için — tel üstünde görünmez (`Message.to_json/1` `id`yi taşır ama
  # id sunucu sırasıdır, decoy'lar da aynı alanı taşır).
  defp real_message do
    {pubkey, priv} = :crypto.generate_key(:eddsa, :ed25519)
    payload = "Yarın sabah dokuzda buluşalım mı, kahve içeriz."
    padding = 4096 - 4 - byte_size(payload)
    body = <<byte_size(payload)::unsigned-big-32, payload::binary, 0::size(padding)-unit(8)>>
    ctr = 1

    sig =
      :crypto.sign(
        :eddsa,
        :none,
        Message.signing_input(@room, @epoch, ctr, body),
        [priv, :ed25519]
      )

    %{id: :real, pubkey: pubkey, sig: sig, body: body, bucket: 4096, ctr: ctr, at: @at}
  end

  defp chi2_critical(df, z) do
    df * :math.pow(1 - 2 / (9 * df) + z * :math.sqrt(2 / (9 * df)), 3)
  end
end
