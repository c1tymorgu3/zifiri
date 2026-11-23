defmodule Zifiri.Mod do
  @moduledoc """
  Moderation, stated as plainly as it can be stated.

  **The operator is the moderator.** There is one moderator, it is whoever runs
  the server, and there is no second party, no jury and no vote. A moderation
  decision is one line in `Zifiri.Mod.Audit`, written by this process;
  `docs/spec.md` §Moderation says what that record does and does not prove.

  **The threshold is 1 of 1.** `threshold/0` returns `1` and every record
  carries `"threshold": 1` with `"signature": null`. The fields exist so the
  move to 2-of-3 is a change of policy and not a change of format: the day
  three holders sign, `threshold` becomes `2`, `signature` becomes a FROST
  threshold signature, and the verifier is already reading both.

  **This module writes; it does not decide.** Nothing here judges a post. It
  records what an operator decided, so that the decision cannot be quietly
  rewritten afterwards.

  ## Why it is a process

  The chain has one dangerous interleaving: two writers both verify the file,
  both see `n` lines, both append `seq: n + 1`. That is a broken chain written
  by a working system, which is worse than a chain an attacker broke. This
  GenServer is the single writer, so appends are serialised; the file itself
  stays a plain append-only JSONL that a third party can read without asking us
  anything.

  It holds no state — the file is the state, and a restart must not be able to
  change what the file says. If the process is not running (a script, a stopped
  application), `record/3` writes directly and the ordering guarantee is gone:
  the chain still verifies, it is just no longer protected from a concurrent
  writer.

  ## What the record is not

  A line here is not a warrant, not a second opinion, and not a check on the
  operator. `actor` is the string the writer typed. See
  `Zifiri.Mod.Audit` for what the chain proves (that the file was not edited
  after the fact) and what it does not (who made the decision).
  """

  use GenServer

  alias Zifiri.Mod.Audit

  # The one moderator, today. A string, not a key: nothing in this build can
  # verify it, and pretending otherwise is the failure mode this module exists
  # to avoid.
  @moderator "operator"

  # 1 of 1. See docs/spec.md §Moderation for the 2-of-3 plan.
  @threshold 1

  @call_timeout 15_000

  # -- identity of the moderator ----------------------------------------------

  @doc "Who moderates. Today: the operator, alone."
  @spec moderator() :: binary()
  def moderator, do: @moderator

  @doc "How many signatures a decision needs. Today: 1 (of 1)."
  @spec threshold() :: pos_integer()
  def threshold, do: @threshold

  @doc """
  Records a moderation decision.

  `action` is what was done (`:hide`, `:restore`, `:erase`, …), `target` is
  what it was done to, and `reason` is the operator's own words — the reason is
  recorded because a decision without one cannot be reviewed, and it is the
  operator's text because nobody else is there to write it.

  Options: `:reason`, `:actor` (defaults to `moderator/0`), `:threshold`,
  `:signature`. Returns `{:ok, record}` or `{:error, reason}`; a broken chain
  is an error, never a silent append.
  """
  @spec record(atom() | binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def record(action, target, opts \\ []) do
    entry = %{
      "actor" => Keyword.get(opts, :actor, @moderator),
      "action" => to_string(action),
      "target" => to_string(target),
      "reason" => Keyword.get(opts, :reason, "")
    }

    append_opts = Keyword.take(opts, [:threshold, :signature, :at, :version])

    case GenServer.whereis(__MODULE__) do
      nil -> Audit.append(entry, append_opts)
      _pid -> GenServer.call(__MODULE__, {:record, entry, append_opts}, @call_timeout)
    end
  end

  @doc "Every recorded decision, in file order."
  @spec history() :: [map()]
  def history, do: Audit.entries()

  @doc "Recomputes the chain. See `Zifiri.Mod.Audit.verify_chain/0`."
  @spec verify() :: {:ok, non_neg_integer()} | {:error, {pos_integer(), term()}}
  def verify, do: Audit.verify_chain()

  # -- server -----------------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    {:ok, %{append: Keyword.get(opts, :append, &Audit.append/2)}}
  end

  @impl true
  def handle_call({:record, entry, opts}, _from, state) do
    {:reply, state.append.(entry, opts), state}
  end
end
