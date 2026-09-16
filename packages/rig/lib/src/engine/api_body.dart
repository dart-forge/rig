import '../spec/container_spec.dart';

/// The body of `POST /containers/create` for [spec].
///
/// [labels] is used as given: merging rig's labels with the caller's happens
/// once, in `buildRigLabels`, so it must not happen again here.
Map<String, Object?> buildCreateBody(
  ContainerSpec spec,
  Map<String, String> labels,
) {
  final ports = spec.exposedPorts.toSet().toList()..sort();

  return {
    'Image': spec.image,
    'Env': [for (final e in spec.env.entries) '${e.key}=${e.value}'],
    if (spec.command.isNotEmpty) 'Cmd': spec.command,
    // An empty Entrypoint is not the same as no Entrypoint: sending [] would
    // clear the image's own.
    if (spec.entrypoint.isNotEmpty) 'Entrypoint': spec.entrypoint,
    'Labels': labels,
    if (spec.user != null) 'User': spec.user,
    if (spec.workingDir != null) 'WorkingDir': spec.workingDir,
    if (ports.isNotEmpty)
      'ExposedPorts': {for (final p in ports) '$p/tcp': <String, Object?>{}},
    if (spec.healthcheck != null)
      'Healthcheck': _healthcheck(spec.healthcheck!),
    'HostConfig': {
      if (ports.isNotEmpty)
        'PortBindings': {
          for (final p in ports)
            '$p/tcp': [
              // An empty HostPort is the whole trick: Docker picks a free
              // port, so no test ever names one and nothing can collide.
              {'HostIp': '127.0.0.1', 'HostPort': ''},
            ],
        },
      if (spec.tmpfs.isNotEmpty)
        'Tmpfs': {for (final path in spec.tmpfs) path: ''},
      if (spec.mounts.isNotEmpty)
        'Binds': [
          for (final m in spec.mounts)
            '${m.hostPath}:${m.containerPath}:${m.readOnly ? 'ro' : 'rw'}',
        ],
      'Privileged': spec.privileged,
      if (spec.networkMode != null) 'NetworkMode': spec.networkMode,
      // Never: a container that disappears on exit cannot be inspected after
      // a failure, and a shared one has to outlive the run that created it.
      'AutoRemove': false,
    },
  };
}

Map<String, Object?> _healthcheck(Healthcheck hc) => {
  'Test': hc.test,
  // Docker takes durations in nanoseconds.
  'Interval': hc.interval.inMicroseconds * 1000,
  'Timeout': hc.timeout.inMicroseconds * 1000,
  'Retries': hc.retries,
  'StartPeriod': hc.startPeriod.inMicroseconds * 1000,
};
