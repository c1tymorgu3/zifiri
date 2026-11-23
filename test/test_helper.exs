# The app is started by `mix test` before this file runs, so the repo pool is
# already up. Migrations are applied here rather than through an alias so that
# a plain `mix test` is enough on CI and on a fresh checkout.
{:ok, _apps} = Application.ensure_all_started(:zifiri)

database = Zifiri.Repo.config()[:database]
File.mkdir_p!(Path.dirname(database))

Ecto.Migrator.run(
  Zifiri.Repo,
  Ecto.Migrator.migrations_path(Zifiri.Repo),
  :up,
  all: true
)

Ecto.Adapters.SQL.Sandbox.mode(Zifiri.Repo, :manual)

ExUnit.start(exclude: [:integration])
