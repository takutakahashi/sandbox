package main

import (
	"fmt"
	"sync"
	"time"
)

func startGoroutines() {
	// 関数ローカルの変数
	localVar := "I am a local variable in startGoroutines"
	
	// 無限ループのgoroutine - localVarをキャプチャします
	go func() {
		count := 0
		for {
			count++
			fmt.Printf("Goroutine 1: %s, Count: %d\n", localVar, count)
			time.Sleep(1 * time.Second)
		}
	}()
	
	// 有限回数実行するgoroutine
	go func() {
		for i := 0; i < 10; i++ {
			fmt.Printf("Goroutine 2: Running iteration %d\n", i)
			time.Sleep(500 * time.Millisecond)
		}
		fmt.Println("Goroutine 2: Finished its work and will exit")
	}()
	
	fmt.Println("startGoroutines function is exiting, but goroutines continue")
}

func main() {
	var wg sync.WaitGroup
	
	fmt.Println("Main: Starting the program")
	
	// WaitGroupを使わずにgoroutineを起動
	startGoroutines()
	
	fmt.Println("Main: startGoroutines has returned")
	
	// メインゴルーチンでの動作も実行
	for i := 0; i < 3; i++ {
		fmt.Printf("Main: Doing work %d\n", i)
		time.Sleep(1 * time.Second)
	}
	
	// 制御されたgoroutineを起動
	wg.Add(1)
	go func() {
		defer wg.Done()
		fmt.Println("Controlled goroutine: Starting")
		for i := 0; i < 3; i++ {
			fmt.Printf("Controlled goroutine: Working %d\n", i)
			time.Sleep(500 * time.Millisecond)
		}
		fmt.Println("Controlled goroutine: Finished")
	}()
	
	// 制御されたgoroutineの完了を待機
	fmt.Println("Main: Waiting for controlled goroutine to finish...")
	wg.Wait()
	fmt.Println("Main: Controlled goroutine is done")
	
	fmt.Println("Main: Program will exit in 2 seconds...")
	time.Sleep(2 * time.Second)
	fmt.Println("Main: Exiting now - all goroutines will be terminated")
}