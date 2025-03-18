package main

import (
	"fmt"
	"sync"
	"time"
)

// Worker goroutineを表す構造体
type Worker struct {
	ID         int
	doneChan   chan struct{}  // 終了シグナル用チャネル
	resultChan chan<- string  // 結果送信用チャネル
	wg         *sync.WaitGroup
}

// NewWorker は新しいWorkerを作成します
func NewWorker(id int, resultChan chan<- string, wg *sync.WaitGroup) *Worker {
	return &Worker{
		ID:         id,
		doneChan:   make(chan struct{}),
		resultChan: resultChan,
		wg:         wg,
	}
}

// Start はワーカーgoroutineを開始します
func (w *Worker) Start() {
	w.wg.Add(1)
	
	go func() {
		defer w.wg.Done()
		
		fmt.Printf("Worker %d: Started\n", w.ID)
		
		ticker := time.NewTicker(1 * time.Second)
		defer ticker.Stop()
		
		count := 0
		
		for {
			select {
			case <-w.doneChan:
				// 終了シグナルを受信
				fmt.Printf("Worker %d: Received stop signal, shutting down\n", w.ID)
				w.resultChan <- fmt.Sprintf("Worker %d final count: %d", w.ID, count)
				return
				
			case <-ticker.C:
				// 定期的な処理
				count++
				fmt.Printf("Worker %d: Working... (count: %d)\n", w.ID, count)
				
				// 結果をメインgoroutineに送信
				w.resultChan <- fmt.Sprintf("Worker %d progress: %d", w.ID, count)
			}
		}
	}()
}

// Stop はワーカーgoroutineを停止します
func (w *Worker) Stop() {
	close(w.doneChan)
}

// WorkerPool はWorkerのコレクションを管理します
type WorkerPool struct {
	workers    []*Worker
	resultChan chan string
	wg         sync.WaitGroup
}

// NewWorkerPool は新しいWorkerPoolを作成します
func NewWorkerPool(numWorkers int) *WorkerPool {
	return &WorkerPool{
		workers:    make([]*Worker, numWorkers),
		resultChan: make(chan string, numWorkers*10), // バッファ付きチャネル
	}
}

// Start はすべてのワーカーを開始します
func (wp *WorkerPool) Start() {
	// 結果を処理するgoroutineを起動
	go wp.processResults()
	
	// ワーカーを開始
	for i := 0; i < len(wp.workers); i++ {
		wp.workers[i] = NewWorker(i, wp.resultChan, &wp.wg)
		wp.workers[i].Start()
	}
}

// processResults は結果チャネルからメッセージを読み取ります
func (wp *WorkerPool) processResults() {
	for msg := range wp.resultChan {
		fmt.Printf("Main: Received message: %s\n", msg)
	}
}

// Stop はすべてのワーカーを停止し、リソースをクリーンアップします
func (wp *WorkerPool) Stop() {
	fmt.Println("Main: Stopping all workers...")
	
	// すべてのワーカーに停止シグナルを送信
	for _, worker := range wp.workers {
		worker.Stop()
	}
	
	// すべてのワーカーが終了するのを待機
	wp.wg.Wait()
	
	// 結果チャネルをクローズ
	close(wp.resultChan)
	
	fmt.Println("Main: All workers have been stopped")
}

func main() {
	fmt.Println("Starting channel-based goroutine management demo")
	
	// 3つのワーカーを持つプールを作成
	pool := NewWorkerPool(3)
	
	// ワーカーを開始
	pool.Start()
	
	// メインプログラムでの処理
	fmt.Println("Main: Doing some work while goroutines are running...")
	time.Sleep(5 * time.Second)
	
	// ワーカーを停止
	pool.Stop()
	
	// プールが完全に終了するのを少し待つ 
	// (結果処理goroutineが残りのメッセージを処理するため)
	time.Sleep(500 * time.Millisecond)
	
	fmt.Println("Main: Program completed successfully")
}