package main

import (
	"fmt"
	"time"
)

// 無限ループを実行するgoroutine
func startInfiniteLoop() {
	go func() {
		count := 0
		for {
			count++
			fmt.Printf("Goroutine is still running. Count: %d\n", count)
			time.Sleep(1 * time.Second)
		}
	}()
	fmt.Println("startInfiniteLoop function is about to exit, but goroutine will continue")
	// この関数はすぐに終了するが、goroutineは継続実行される
}

func main() {
	fmt.Println("Main: Starting the program")
	
	// 無限ループのgoroutineを起動
	startInfiniteLoop()
	
	fmt.Println("Main: startInfiniteLoop has returned, waiting for 5 seconds...")
	// メインプログラムは5秒待機
	time.Sleep(5 * time.Second)
	
	fmt.Println("Main: Program will exit now, but what happens to the goroutine?")
	fmt.Println("Main: Exiting...")
	
	// メインプログラムが終了すると、全てのgoroutineも強制終了となる
}