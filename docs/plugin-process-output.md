# Plugin process output

`yina.utils.exec(file, args, cwd, stdoutHook, stderrHook)` keeps its existing result:
`{status, stdout, stderr}`. Output is collected in temporary files while the
process runs and converted to strings after both pipes reach EOF. The returned
strings can still use memory proportional to the complete output.

For large output, call
`yina.utils.execWithOptions(file, args, cwd, stdoutHook, stderrHook, options)`.
The options are:

| Option | Value | Result |
| --- | --- | --- |
| `output` | `"text"` (default) or `"files"` | `"files"` returns `{status, stdoutFile, stderrFile}` with absolute paths in the plugin's `@tmp` directory. The plugin owns these files. |
| `maxOutputBytes` | Nonnegative integer | Rejects the promise if combined stdout and stderr exceed the limit. No successful result is truncated. |

Hooks receive UTF-8 chunks on the JavaScript thread while the process runs.
The process is terminated if its owner plugin instance unloads. HTTP requests
and downloads are cancelled on unload as well. Downloads write through a
temporary file in the destination folder and replace the destination after a
successful transfer.
