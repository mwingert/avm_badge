# The atomvm and badge tasks build the firmware; anything else on the host
# is the simulator, unless MIX_TARGET says otherwise.
if System.get_env("MIX_TARGET") == nil do
  case System.argv() do
    ["atomvm." <> _ | _] -> Mix.target(:badge)
    ["badge." <> _ | _] -> Mix.target(:badge)
    _other -> :ok
  end
end

defmodule Badge.MixProject do
  use Mix.Project

  def project do
    [
      app: :avm_badge,
      version: "0.1.1",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.target()),
      test_paths: test_paths(Mix.target()),
      deps: deps(),
      # The flash task bypasses the packbeam alias, so both write application.bin first.
      aliases: [
        "atomvm.application_bin": &application_bin/1,
        "atomvm.packbeam": ["atomvm.application_bin", "atomvm.packbeam"],
        "atomvm.esp32.flash": ["atomvm.application_bin", "atomvm.esp32.flash"]
      ],
      atomvm: [
        start: Badge,
        flash_offset: 0x2B8000,
        chip: "esp32s3",
        port: "auto"
      ]
    ]
  end

  # The simulator is an OTP application; the badge starts from `Badge.start/0`
  # and the simulator's tests start the board themselves.
  def application do
    [extra_applications: [:logger]] ++ mod(Mix.target(), Mix.env())
  end

  defp mod(:host, env) when env != :test, do: [mod: {Badge.Sim.Application, []}]
  defp mod(_target, _env), do: []

  # Firmware builds (any atomvm.* task) leave the host-only Mix tasks out of main.avm.
  defp elixirc_paths(:badge), do: if(firmware_build?(), do: ["lib"], else: ["lib", "mix"])
  defp elixirc_paths(_target), do: ["lib", "mix", "sim/lib"]

  defp firmware_build?, do: match?(["atomvm." <> _ | _], System.argv())

  # ExAtomVM writes no priv/application.bin, and NervesHub cannot identify firmware without one.
  defp application_bin(_args) do
    config = Mix.Project.config()
    app = Keyword.fetch!(config, :app)

    term =
      {:application, app,
       [
         {:description, String.to_charlist(config[:description] || to_string(app))},
         {:vsn, String.to_charlist(Keyword.fetch!(config, :version))},
         {:registered, []},
         {:applications, [:kernel, :stdlib]}
       ]}

    File.mkdir_p!("priv")
    File.write!("priv/application.bin", :erlang.term_to_binary(term))
    # Mix links priv into _build when it compiles; on a clean tree priv did not exist then.
    Mix.Project.build_structure()
    Mix.shell().info("priv/application.bin: #{app} #{config[:version]}")
  end

  defp test_paths(:badge), do: ["test"]
  defp test_paths(_target), do: ["test", "sim/test"]

  defp deps do
    [
      {:exatomvm,
       github: "atomvm/ExAtomVM",
       ref: "ff7daf7e83a4e86fbf078730b6c49045a99de9f8",
       runtime: false},
      # The Erlang side of the port driver built into the VM. A rebar3
      # project, so mix is told which manager to use.
      {:atomvm_websocket_client,
       github: "nerves-hub/atomvm_websocket_client",
       ref: "011b99c30bea5253eb29558e3c6ac420a5472c0f",
       manager: :rebar3},
      # The NervesHub agent, and its Elixir face. The override stops the
      # wrapper fetching its own unpinned copy of the agent.
      {:nerves_hub_link_atomvm_esp32_ex,
       github: "nerves-hub/nerves_hub_link_atomvm_esp32_ex",
       ref: "b9f8a01868d41fcf25bfafe8dd6dc62f61498e52"},
      {:nerves_hub_link_atomvm_esp32,
       github: "nerves-hub/nerves_hub_link_atomvm_esp32",
       ref: "b5d57f945114c0687d519cbd23a7b210d48c5fdc",
       manager: :rebar3,
       override: true},
      # The packbeam escript, from Hex rather than an AtomVM checkout.
      {:atomvm_packbeam, "~> 0.8.2", runtime: false},
      # The browser side of the simulator, absent from the badge build.
      {:phoenix_playground, "~> 0.1.9", targets: [:host]}
    ]
  end
end
