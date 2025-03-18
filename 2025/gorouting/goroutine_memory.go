package main

import (
	"fmt"
	"runtime"
	"time"
)

func parentFunction() {
	message := "This is a message from the parent function"
	counter := 0
	
	// メモリアドレスを表示
	fmt.Printf("Parent: 'message' variable address: %p\n", &message)
	fmt.Printf("Parent: 'counter' variable address: %p\n", &counter)
	
	// goroutineを起動してローカル変数をキャプチャ
	go func() {
		// この時点で親関数のスタックフレームは終了しているが
		// goroutineは変数のコピーを持っているか、ヒープに昇格した変数を参照している
		for {
			counter++
			fmt.Printf("Goroutine: Using parent's variables - message: '%s', counter: %d\n", message, counter)
			fmt.Printf("Goroutine: 'message' address: %p, 'counter' address: %p\n", &message, &counter)
			time.Sleep(1 * time.Second)
		}
	}()
	
	// ゴミ収集を促進
	runtime.GC()
	
	fmt.Println("Parent: Function is about to exit")
}

func main() {
	fmt.Println("Main: Starting program")
	
	parentFunction()
	
	fmt.Println("Main: parentFunction has returned but its goroutine continues")
	
	// ガベージコレクションを強制的に実行
	fmt.Println("Main: Forcing garbage collection")
	runtime.GC()
	
	// メモリの状態を確認
	var memStats runtime.MemStats
	runtime.ReadMemStats(&memStats)
	fmt.Printf("Main: Current memory usage - Alloc: %v bytes\n", memStats.Alloc)
	
	fmt.Println("Main: Waiting for 5 seconds to observe goroutine behavior...")
	time.Sleep(5 * time.Second)
	
	fmt.Println("Main: Program exiting")
}