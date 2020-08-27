{application, 'prometheus_ranch', [
	{description, "Prometheus collector for Ranch"},
	{vsn, "0.2.0"},
	{modules, ['prometheus_ranch_collector']},
	{registered, []},
	{applications, [kernel,stdlib,protobuffs,prometheus]},
	{env, []}
]}.