import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production
# configuration and secrets from environment variables.

# horus 0.4.0 (transitive via khepri) calls `:code.get_object_code(:erlang)` at
# runtime, which requires `erts/ebin/erlang.beam` to be on the code path. Mix
# releases don't bundle erts/ebin, and `include_erts: false` doesn't add it
# either — the runtime starts with no erts path. Resolve the system OTP's erts
# dir and prepend it. Runs in all environments; in dev/test the path is
# already there and `add_pathz` is a no-op.
if config_env() == :prod do
  lib_dir = :code.lib_dir()

  case File.ls(List.to_string(lib_dir)) do
    {:ok, names} ->
      case Enum.find(names, &String.starts_with?(&1, "erts-")) do
        nil ->
          :ok

        erts_name ->
          erts_ebin = Path.join([List.to_string(lib_dir), erts_name, "ebin"])

          if File.dir?(erts_ebin) do
            _ = :code.add_pathz(String.to_charlist(erts_ebin))
          end
      end

    _ ->
      :ok
  end
end
