package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	DefaultStoreDir = `D:\Temp\procman`
	detachedProc    = 0x00000008
	createNoWindow  = 0x08000000
)

var (
	counterMu sync.Mutex
	// key: "YYYYMMDD_HHMMSS", value: 当前秒内已使用的最大序号
	secondCounters = make(map[string]int)
)

type ProcessManager struct {
	store   string
	id      string
	cmdArgs []string
	workDir string
	hidden  bool
	env     []string
}

func NewProcessManager(store string) *ProcessManager {
	return &ProcessManager{store: store, hidden: true}
}

func (pm *ProcessManager) base() string { return filepath.Join(pm.store, pm.id) }
func (pm *ProcessManager) Paths() (string, string, string, string) {
	base := pm.base()
	return base + "/stdout.txt", base + "/stderr.txt", base + "/pid.txt", base + "/cmd.txt"
}

func (pm *ProcessManager) SetWorkDir(d string) *ProcessManager {
	pm.workDir = d
	return pm
}
func (pm *ProcessManager) SetVisible() *ProcessManager {
	pm.hidden = false
	return pm
}
func (pm *ProcessManager) SetEnv(kv ...string) *ProcessManager {
	pm.env = append(pm.env, kv...)
	return pm
}
func (pm *ProcessManager) SetArgs(args []string) *ProcessManager {
	pm.cmdArgs = args
	return pm
}
func (pm *ProcessManager) ID() string {
	return pm.id
}
func (pm *ProcessManager) Load(store, id string) *ProcessManager {
	pm.store, pm.id = store, id
	return pm
}

// 生成唯一ID：格式 YYYYMMDD_HHMMSS_序号（序号从001开始，同一秒内递增，最大999）
func generateUniqueID(store string) (string, error) {
	const maxRetries = 10
	for retry := 0; retry < maxRetries; retry++ {
		now := time.Now()
		secKey := now.Format("20060102_150405") // 精确到秒
		counterMu.Lock()
		nextSeq := secondCounters[secKey] + 1
		if nextSeq > 999 {
			// 这一秒的序号已用完，等待下一秒
			counterMu.Unlock()
			time.Sleep(1 * time.Second - time.Duration(now.Nanosecond()))
			continue
		}
		secondCounters[secKey] = nextSeq
		counterMu.Unlock()

		id := fmt.Sprintf("%s_%03d", secKey, nextSeq)

		// 检查目录是否已存在（防止与手动创建或残留目录冲突）
		if _, err := os.Stat(filepath.Join(store, id)); os.IsNotExist(err) {
			return id, nil
		}
		// 目录已存在，说明序号冲突（可能被人为占用），继续递增
		// 不需要解锁，因为我们已经在 map 中占用了该序号，但实际目录存在，
		// 我们可以继续尝试下一个序号（需要回滚当前序号并重试）
		counterMu.Lock()
		delete(secondCounters, secKey) // 清除这个冲突的序号，下次重新取
		counterMu.Unlock()
		// 继续循环，会重新获取当前时间（可能跨秒）
	}
	return "", fmt.Errorf("无法生成唯一ID，请稍后重试")
}

func (pm *ProcessManager) Start() (int, error) {
	id, err := generateUniqueID(pm.store)
	if err != nil {
		return 0, err
	}
	pm.id = id

	if err := os.MkdirAll(pm.base(), 0755); err != nil {
		return 0, fmt.Errorf("创建目录失败: %w", err)
	}

	stdout, stderr, pidFile, cmdFile := pm.Paths()
	outF, _ := os.Create(stdout)
	errF, _ := os.Create(stderr)

	cmd := exec.Command(pm.cmdArgs[0], pm.cmdArgs[1:]...)
	cmd.Dir = pm.workDir
	cmd.Stdout, cmd.Stderr = outF, errF
	cmd.Env = append(os.Environ(), pm.env...)

	flags := syscall.CREATE_NEW_PROCESS_GROUP | detachedProc
	if pm.hidden {
		flags |= createNoWindow
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: uint32(flags)}

	if err := cmd.Start(); err != nil {
		outF.Close()
		errF.Close()
		return 0, fmt.Errorf("启动失败: %w", err)
	}
	outF.Close()
	errF.Close()

	_ = os.WriteFile(cmdFile, []byte(strings.Join(pm.cmdArgs, " ")+"\n"), 0644)
	_ = os.WriteFile(pidFile, []byte(strconv.Itoa(cmd.Process.Pid)+"\n"), 0644)

	return cmd.Process.Pid, nil
}

func (pm *ProcessManager) Kill() error {
	data, err := os.ReadFile(pm.base() + "/pid.txt")
	if err != nil {
		return fmt.Errorf("读取PID失败: %w", err)
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(data)))
	proc, _ := os.FindProcess(pid)
	return proc.Kill()
}

func isProcessAlive(pid int) bool {
	const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
	handle, err := syscall.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
	if err != nil {
		return false
	}
	defer syscall.CloseHandle(handle)
	var exitCode uint32
	err = syscall.GetExitCodeProcess(handle, &exitCode)
	if err != nil {
		return false
	}
	return exitCode == 259
}

func listRunningProcesses(storeDir string) error {
	entries, err := os.ReadDir(storeDir)
	if err != nil {
		return fmt.Errorf("读取 store 目录失败: %w", err)
	}
	fmt.Printf("%-24s %-8s %s\n", "ID", "PID", "COMMAND")
	fmt.Println(strings.Repeat("-", 80))
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		id := entry.Name()
		pidPath := filepath.Join(storeDir, id, "pid.txt")
		cmdPath := filepath.Join(storeDir, id, "cmd.txt")
		pidData, err := os.ReadFile(pidPath)
		if err != nil {
			continue
		}
		pid, err := strconv.Atoi(strings.TrimSpace(string(pidData)))
		if err != nil {
			continue
		}
		if !isProcessAlive(pid) {
			continue
		}
		cmd := ""
		if cmdData, err := os.ReadFile(cmdPath); err == nil {
			cmd = strings.TrimSpace(string(cmdData))
		}
		fmt.Printf("%-24s %-8d %s\n", id, pid, cmd)
	}
	return nil
}

func findCmdArgs(args []string) []string {
	for i, v := range args {
		if v == "--" {
			return args[i+1:]
		}
	}
	return nil
}

func usage(prog string) {
	fmt.Fprintf(os.Stderr, `用法:
  %s start [选项] -- <命令...>
    选项: -cwd <目录>     工作目录
          -no-hidden    显示窗口
    示例: %s start -- java -jar app.jar
  %s kill -id <id>
  %s ps
`, prog, prog, prog, prog)
}

func main() {
	if len(os.Args) < 2 {
		usage(os.Args[0])
		os.Exit(1)
	}
	switch os.Args[1] {
	case "start":
		fs := flag.NewFlagSet("start", flag.ExitOnError)
		cwd, visible := fs.String("cwd", "", ""), fs.Bool("no-hidden", false, "")
		fs.Parse(os.Args[2:])
		cmdArgs := findCmdArgs(os.Args[2:])
		if len(cmdArgs) == 0 {
			fmt.Fprintln(os.Stderr, "错误: 需要指定命令")
			usage(os.Args[0])
			os.Exit(1)
		}
		pm := NewProcessManager(DefaultStoreDir).SetWorkDir(*cwd).SetArgs(cmdArgs)
		if *visible {
			pm.SetVisible()
		}
		pid, err := pm.Start()
		if err != nil {
			fmt.Fprintf(os.Stderr, "错误: %v\n", err)
			os.Exit(1)
		}

		stdout, stderr, _, _ := pm.Paths()
		fmt.Fprintf(os.Stderr, "Cmd `%s` started\n", strings.Join(cmdArgs, " "))
		fmt.Fprintf(os.Stderr, "Stdout redirect to `%s`\n", stdout)
		fmt.Fprintf(os.Stderr, "Stderr redirect to `%s`\n", stderr)

		fmt.Printf("ID: %s\n PID = %d", pm.ID(), pid)
	case "kill":
		fs := flag.NewFlagSet("kill", flag.ExitOnError)
		id := fs.String("id", "", "")
		fs.Parse(os.Args[2:])
		if *id == "" {
			fmt.Fprintln(os.Stderr, "错误: 需要 -id 参数")
			usage(os.Args[0])
			os.Exit(1)
		}
		if err := NewProcessManager(DefaultStoreDir).Load(DefaultStoreDir, *id).Kill(); err != nil {
			fmt.Fprintf(os.Stderr, "错误: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("进程 %s 已终止\n", *id)
	case "ps":
		if err := listRunningProcesses(DefaultStoreDir); err != nil {
			fmt.Fprintf(os.Stderr, "错误: %v\n", err)
			os.Exit(1)
		}
	default:
		usage(os.Args[0])
		os.Exit(1)
	}
}