package main

import (
	"crypto/rand"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
)

const DETACHED_PROCESS = 0x00000008

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "-start":
		handleStart()
	case "-kill":
		handleKill()
	default:
		printUsage()
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Fprintf(os.Stderr, "用法:\n")
	fmt.Fprintf(os.Stderr, "  启动: %s -start [启动器选项] -- <命令...>\n", os.Args[0])
	fmt.Fprintf(os.Stderr, "        启动器选项:\n")
	fmt.Fprintf(os.Stderr, "          -cwd <目录>   指定工作目录\n")
	fmt.Fprintf(os.Stderr, "        例如: %s -start -- java -jar app.jar\n", os.Args[0])
	fmt.Fprintf(os.Stderr, "        例如: %s -start -cwd D:\\myapp -- java -jar app.jar\n", os.Args[0])
	fmt.Fprintf(os.Stderr, "  停止: %s -kill <id>\n", os.Args[0])
}

func handleStart() {
	// 从 os.Args[2:] 中提取启动器选项与命令
	args := os.Args[2:]
	sepIdx := -1
	for i, arg := range args {
		if arg == "--" {
			sepIdx = i
			break
		}
	}
	if sepIdx == -1 {
		fmt.Fprintf(os.Stderr, "错误: 必须使用 '--' 分隔启动器选项与命令\n")
		printUsage()
		os.Exit(1)
	}

	launcherArgs := args[:sepIdx]   // 启动器选项部分
	cmdArgs := args[sepIdx+1:]      // 命令及参数

	if len(cmdArgs) == 0 {
		fmt.Fprintf(os.Stderr, "错误: '--' 后没有提供要执行的命令\n")
		os.Exit(1)
	}

	// 解析启动器选项
	var workDir string
	skipNext := false
	for i, a := range launcherArgs {
		if skipNext {
			skipNext = false
			continue
		}
		if a == "-cwd" {
			if i+1 >= len(launcherArgs) {
				fmt.Fprintf(os.Stderr, "错误: -cwd 后必须指定目录路径\n")
				os.Exit(1)
			}
			workDir = launcherArgs[i+1]
			skipNext = true
		} else {
			fmt.Fprintf(os.Stderr, "错误: 未知的启动器选项: %s\n", a)
			printUsage()
			os.Exit(1)
		}
	}

	// 要执行的命令字符串（用于写入 cmd.txt）
	commandStr := strings.Join(cmdArgs, " ")

	// 生成唯一 ID
	id := generateID()
	outDir := "C:\\" + id

	// 创建输出目录
	if err := os.MkdirAll(outDir, 0755); err != nil {
		fmt.Fprintf(os.Stderr, "创建目录失败: %v\n", err)
		os.Exit(1)
	}

	// 输出文件路径
	stdoutPath := outDir + "\\stdout.txt"
	stderrPath := outDir + "\\stderr.txt"
	pidPath := outDir + "\\pid.txt"
	cmdPath := outDir + "\\cmd.txt"

	// 打开 stdout/stderr 文件
	stdoutFile, err := os.Create(stdoutPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "创建 stdout 文件失败: %v\n", err)
		os.Exit(1)
	}
	stderrFile, err := os.Create(stderrPath)
	if err != nil {
		stdoutFile.Close()
		fmt.Fprintf(os.Stderr, "创建 stderr 文件失败: %v\n", err)
		os.Exit(1)
	}

	// 写入 cmd.txt
	if err := os.WriteFile(cmdPath, []byte(commandStr+"\n"), 0644); err != nil {
		stdoutFile.Close()
		stderrFile.Close()
		fmt.Fprintf(os.Stderr, "写入 cmd.txt 失败: %v\n", err)
		os.Exit(1)
	}

	// 构造命令
	cmd := exec.Command(cmdArgs[0], cmdArgs[1:]...)
	cmd.Stdout = stdoutFile
	cmd.Stderr = stderrFile

	// 设置工作目录（如果指定）
	if workDir != "" {
		cmd.Dir = workDir
	}

	// 脱离控制台（Windows）
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP | DETACHED_PROCESS,
	}

	// 启动子进程
	if err := cmd.Start(); err != nil {
		stdoutFile.Close()
		stderrFile.Close()
		fmt.Fprintf(os.Stderr, "启动进程失败: %v\n", err)
		os.Exit(1)
	}

	// 写入 PID 到 pid.txt
	pidStr := strconv.Itoa(cmd.Process.Pid)
	if err := os.WriteFile(pidPath, []byte(pidStr+"\n"), 0644); err != nil {
		fmt.Fprintf(os.Stderr, "警告: 写入 pid.txt 失败: %v\n", err)
	} else {
		// 可选调试信息，不影响 id 的标准输出
		fmt.Fprintf(os.Stderr, "PID %s 已写入 %s\n", pidStr, pidPath)
	}

	// 打印 ID 到标准输出
	fmt.Println(id)
	os.Exit(0)
}

func handleKill() {
	if len(os.Args) < 3 {
		fmt.Fprintf(os.Stderr, "错误: -kill 后必须提供 id\n")
		os.Exit(1)
	}
	id := os.Args[2]
	pidPath := "C:\\" + id + "\\pid.txt"

	data, err := os.ReadFile(pidPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "无法读取 %s: %v\n", pidPath, err)
		os.Exit(1)
	}

	pidStr := strings.TrimSpace(string(data))
	pid, err := strconv.Atoi(pidStr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "无效的 PID 内容: %s\n", pidStr)
		os.Exit(1)
	}

	proc, err := os.FindProcess(pid)
	if err != nil {
		fmt.Fprintf(os.Stderr, "查找进程失败: %v\n", err)
		os.Exit(1)
	}

	if err := proc.Kill(); err != nil {
		fmt.Fprintf(os.Stderr, "终止进程失败: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("进程 %d (id: %s) 已终止\n", pid, id)
}

func generateID() string {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return fmt.Sprintf("%x", b)
}