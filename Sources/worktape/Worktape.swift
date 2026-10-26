import Darwin
import Foundation

@main
struct Worktape {
    static func main() async {
        switch Array(CommandLine.arguments.dropFirst()) {
        case ["record"]:
            exit(await record())
        case let arguments where arguments.count == 2 && arguments[0] == "record" && !arguments[1].hasPrefix("-"):
            exit(await record(arguments[1]))
        case ["stop"]:
            exit(stop())
        case ["init"]:
            exit(initialise(FileManager.default.currentDirectoryPath))
        case ["hook", "zsh"]:
            print(zshHook, terminator: "")
        case ["help"], ["--help"], ["-h"]:
            print(usage)
        default:
            fputs(usage + "\n", stderr)
            exit(EX_USAGE)
        }
    }
}

let usage = """
usage: worktape <command>

  init                    set up .worktapes/ in this directory
  record [description]    record this terminal and the windows opened from it
  stop                    stop the recording this shell is part of
  hook zsh                print a zsh hook that reminds you to record
"""

func stop() -> Int32 {
    guard let value = ProcessInfo.processInfo.environment["WORKTAPE_PID"],
          let pid = pid_t(value),
          name(of: pid) == "worktape"
    else {
        log("not recording")
        return 1
    }
    kill(pid, SIGTERM)
    return 0
}

func log(_ message: String) {
    fputs("worktape: \(message)\n", stderr)
}

func initialise(_ directory: String) -> Int32 {
    let project = Project(root: directory)
    let ignore = (project.recordings as NSString).appendingPathComponent(".gitignore")
    guard !FileManager.default.fileExists(atPath: ignore) else {
        log("\(project.name) is already set up")
        return 1
    }
    do {
        try FileManager.default.createDirectory(atPath: project.recordings, withIntermediateDirectories: true)
        try Data("*\n".utf8).write(to: URL(filePath: ignore))
    } catch {
        log("can't create \(project.recordings): \(error.localizedDescription)")
        return 1
    }
    log("set up .worktapes/ in \(project.name), run worktape record to start")
    return 0
}

let zshHook = #"""
typeset -g _worktape_warned
_worktape_prompt() {
  psvar[7,9]=('' '' '')
  if [[ -n $WORKTAPE_RECORDING ]]; then
    if [[ -e $WORKTAPE_STATE/paused ]]; then
      psvar[9]=1
    else
      psvar[8]=1
    fi
  else
    local dir=$PWD
    until [[ -d $dir/.worktapes ]]; do
      [[ $dir == / ]] && { _worktape_warned=; return }
      dir=${dir:h}
    done
    psvar[7]=1
    if [[ $dir != $_worktape_warned ]]; then
      _worktape_warned=$dir
      print -P -u2 -- '%F{yellow}○ worktape not recording%f'
    fi
  fi
  local mark='%(7V.%F{yellow}○%f .)%(8V.%F{red}●%f .)%(9V.%F{yellow}‖%f .)'
  [[ $PROMPT == *"$mark" ]] || PROMPT+=$mark
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _worktape_prompt

if [[ -n $WORKTAPE_RECORDING ]]; then
  TRAPWINCH() {
    _worktape_prompt
    zle && zle reset-prompt
  }
  [[ -d $WORKTAPE_STATE ]] && : > $WORKTAPE_STATE/prompt
fi

"""#
