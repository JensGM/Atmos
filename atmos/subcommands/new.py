from atmos import ConfigError


def cmd_new(args, cache):
    namespace = args.namespace

    if ':' in namespace or namespace == 'default':
        raise ConfigError(f'invalid namespace name {namespace}')

    namespaces = set(cache.get('namespaces', ()))
    if namespace in namespaces:
        raise ConfigError(f'namespace {namespace} already exists')

    namespaces.add(namespace)
    cache['namespaces'] = namespaces
