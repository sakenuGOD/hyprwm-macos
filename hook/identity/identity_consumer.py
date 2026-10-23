"""ROOT-ONLY live reader CLI; importing this module performs no WS calls."""
import argparse
import ctypes
import json

from identity_protocol import NativeReader, parse_snapshot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('connection', type=int)
    parser.add_argument('pid', type=int)
    parser.add_argument('library')
    parser.add_argument('--full', action='store_true')
    args = parser.parse_args()
    sl = ctypes.CDLL('/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight')
    sl.SLSNewConnection.argtypes = (ctypes.c_void_p, ctypes.POINTER(ctypes.c_int))
    sl.SLSReleaseConnection.argtypes = (ctypes.c_int,)
    caller = ctypes.c_int()
    result = sl.SLSNewConnection(None, ctypes.byref(caller))
    if result or not caller.value:
        raise OSError(result, 'reader connection creation failed')
    try:
        snapshot = parse_snapshot(NativeReader(args.library, caller.value).read(args.connection, args.pid))
        if args.full:
            print(json.dumps(snapshot.raw, sort_keys=True))
        else:
            fields = ('pid', 'launch', 'generation', 'publication', 'seq', 'revision',
                      'settled_revision', 'reconcile_pending', 'installed', 'complete', 'gap')
            print(json.dumps(dict({key: snapshot.raw[key] for key in fields}, ready=snapshot.ready,
                                  windows=len(snapshot.windows), groups=len(snapshot.groups)), sort_keys=True))
    finally:
        result = sl.SLSReleaseConnection(caller.value)
        if result:
            raise OSError(result, 'reader connection release failed')


if __name__ == '__main__':
    main()
