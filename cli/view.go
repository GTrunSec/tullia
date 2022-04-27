package main

import (
	"fmt"
	"strings"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/input-output-hk/tullia/dag"
	"github.com/kr/pretty"
	"github.com/muesli/reflow/wrap"
)

func (m *Model) View() string {
	footer := m.viewFooter()
	footerHeight := lipgloss.Height(footer)

	right := lipgloss.NewStyle().
		Width(m.rightWidth()).
		MaxWidth(m.rightWidth()).
		Height(m.height - footerHeight).
		MaxHeight(m.height - footerHeight).
		Render(m.viewLog())

	if m.logOnly {
		return lipgloss.JoinVertical(0, right, footer)
	} else {
		height := m.height - (2 + footerHeight)
		leftTop := lipgloss.NewStyle().
			Padding(0, 1).
			Width((m.width/2)-1).
			Height((height/2)-1).
			Border(lipgloss.NormalBorder(), true).
			Render(m.viewTasks())

		leftBot := lipgloss.NewStyle().
			Padding(0, 1).
			Width((m.width/2)-1).
			Height((height/2)-1).
			Border(lipgloss.NormalBorder(), true).
			Render(m.viewTask())

		return lipgloss.JoinVertical(0,
			lipgloss.JoinHorizontal(0,
				lipgloss.JoinVertical(0, leftTop, leftBot), right), footer)
	}
}

func (m *Model) viewTask() string {
	task, err := m.getCursorItem()
	if err != nil {
		return "no task selected"
	}

	lines := []string{}

	add := func(key string, value interface{}) {
		var v string
		switch value.(type) {
		case string, time.Duration, error:
			v = pretty.Sprintf("%9s: %s", key, value)
		case int:
			v = pretty.Sprintf("%9s: %d", key, value)
		default:
			v = pretty.Sprintf("%9s: %# v", key, value)
		}
		lines = append(lines, v)
	}

	add("Name", task.Name())
	add("Stage", task.Stage())
	if elapsed := task.Elapsed(); elapsed != 0 {
		add("Duration", task.Elapsed())
	}

	if pid := task.Pid(); pid != 0 {
		add("PID", pid)
	}

	if rss := task.RSS(); rss != "" {
		add("RSS", task.RSS())
	}

	if ps := task.ProcessState(); ps != nil {
		add("Status", task.ProcessState().String())
		if rusage, ok := ps.SysUsage().(*syscall.Rusage); ok {
			utime := timevalToDuration(rusage.Utime)
			stime := timevalToDuration(rusage.Stime)
			add("CPU (user system total)", fmt.Sprintf("%s %s %s", utime, stime, utime+stime))
		}
	}

	if err := task.Error(); err != nil {
		add("Error", err.Error())
	}

	return lipgloss.JoinVertical(0, lines...)
}

func timevalToDuration(t syscall.Timeval) time.Duration {
	return (time.Duration(t.Sec) * time.Second) + (time.Duration(t.Usec) * time.Microsecond)
}

func (m *Model) rightWidth() int {
	if m.logOnly {
		return m.width
	} else {
		return (m.width / 2) - 3
	}
}

func (m *Model) viewLog() string {
	common := lipgloss.NewStyle().
		MaxWidth(m.rightWidth()).
		Width(m.rightWidth())
	stderr := common.Foreground(lipgloss.Color("#E62B0B"))
	stdout := common.Foreground(lipgloss.Color("#EEEEEE"))

	task, err := m.getCursorItem()
	if err != nil {
		return "select a task"
	}

	var lines []dag.Line
	switch m.scroll {
	case -1:
		lines = task.Head(m.height - 4)
	case -2:
		lines = task.Tail(m.height - 4)
	default:
		lines = task.Log(int(m.scroll), m.height-4)
	}

	res := []string{}
	var style lipgloss.Style
	for _, line := range lines {
		switch line.Type {
		case dag.LineTypeStderr:
			style = stderr
		case dag.LineTypeStdout:
			style = stdout
		}
		res = append(res, style.Render(wrap.String(line.Text, m.rightWidth())))
	}

	return lipgloss.JoinVertical(0, res...)
}

var taskStyle = lipgloss.NewStyle().MaxHeight(1)

func (m *Model) viewTasks() string {
	nameLen := 0
	for _, task := range m.dag.Tasks {
		if nameLen < len(task.Name()) {
			nameLen = len(task.Name())
		}
	}

	format := fmt.Sprintf("%%1s %%3s %%-%ds %%5s %%10s", nameLen)

	lines := []string{
		fmt.Sprintf(format, "", "", "name", "stage", "time"),
	}
	width := (m.width / 2) - 5

	for i, task := range m.dag.Tasks {
		style := taskStyle.Copy().Width(width)
		selected := " "
		done := "[ ]"

		if i == m.cursor {
			selected = ">"
		}

		switch task.Stage() {
		case "wait":
			style = style.Foreground(lipgloss.Color("#E6F20C"))
		case "eval":
			style = style.Foreground(lipgloss.Color("#02735E"))
		case "build":
			style = style.Foreground(lipgloss.Color("#0CF2BD"))
		case "run":
			style = style.Foreground(lipgloss.Color("#0DFC69"))
		case "done":
			done = "[✓]"
			style = style.Foreground(lipgloss.Color("#00E600"))
		case "error":
			done = "[X]"
			style = style.Foreground(lipgloss.Color("#E62B0B"))
		}

		line := fmt.Sprintf(format, selected, done, task.Name(), task.Stage(), task.Elapsed().Round(1*time.Millisecond))
		lines = append(lines, style.Render(line))
	}

	return lipgloss.NewStyle().MaxWidth(width).Render(strings.Join(lines, "\n"))
}

func (m *Model) viewFooter() string {
	styles := []lipgloss.Style{}
	texts := []string{}

	if m.lastMsg != nil {
		styles = append(styles, lipgloss.NewStyle())

		switch msg := m.lastMsg.(type) {
		case tea.KeyMsg:
			texts = append(texts, fmt.Sprintf("Last Msg:\n%s", msg))
		default:
			texts = append(texts, pretty.Sprintf("Last Msg:\n%s", msg))
		}
	}

	if m.lastErr != nil {
		styles = append(styles, lipgloss.NewStyle().Foreground(lipgloss.Color("#f00")))
		texts = append(texts, pretty.Sprintf("Last Error:\n%# v", m.lastErr))
	}

	if m.dbg != nil {
		styles = append(styles, lipgloss.NewStyle().Foreground(lipgloss.Color("#0ff")))
		texts = append(texts, pretty.Sprintf("Last Dbg:\n%# v", m.dbg))
	}

	footerParts := make([]string, len(styles))
	if len(styles) > 0 {
		width := m.width / len(styles)
		for i, style := range styles {
			text := wrap.String(texts[i], width)
			footerParts[i] = style.Width(width).MaxWidth(width).Render(text)
		}
	}

	return lipgloss.JoinVertical(0,
		lipgloss.JoinHorizontal(0, footerParts...),
		m.help.View(m.keys))
}
