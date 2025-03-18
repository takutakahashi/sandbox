package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"sync"
	"time"

	"github.com/gammazero/workerpool"
	"golang.org/x/sync/errgroup"
)

// -------------------------------
// errgroup を使用したサンプル
// -------------------------------

// モックの API リクエスト関数（ランダムに成功または失敗）
func fetchAPI(ctx context.Context, apiID int) (string, error) {
	// ランダムな遅延を追加して非同期処理をシミュレート
	delay := time.Duration(rand.Intn(500)+100) * time.Millisecond
	
	select {
	case <-ctx.Done():
		return "", ctx.Err()
	case <-time.After(delay):
		// ランダムにエラーを発生させる
		if rand.Intn(10) < 2 {
			return "", fmt.Errorf("API %d request failed", apiID)
		}
		return fmt.Sprintf("API %d data", apiID), nil
	}
}

// errgroup を使った複数のリクエスト処理
func fetchWithErrGroup(ctx context.Context, apiCount int) ([]string, error) {
	g, gCtx := errgroup.WithContext(ctx)
	results := make([]string, apiCount)
	
	// エラーが発生したら他のgoroutineもキャンセルされるコンテキスト
	
	for i := 0; i < apiCount; i++ {
		i := i // ループ変数をキャプチャ
		
		g.Go(func() error {
			data, err := fetchAPI(gCtx, i)
			if err != nil {
				log.Printf("Error fetching API %d: %v", i, err)
				return err
			}
			
			results[i] = data
			return nil
		})
	}
	
	// すべてのgoroutineが完了するのを待機
	if err := g.Wait(); err != nil {
		return nil, err
	}
	
	return results, nil
}

func demonstrateErrGroup() {
	fmt.Println("\n=== errgroup Example ===")
	
	// タイムアウト付きコンテキスト
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	
	// errgroup を使用してリクエスト
	results, err := fetchWithErrGroup(ctx, 5)
	if err != nil {
		fmt.Printf("Error with errgroup approach: %v\n", err)
	} else {
		fmt.Println("All requests successful:")
		for i, res := range results {
			fmt.Printf(" - API %d result: %s\n", i, res)
		}
	}
}

// -------------------------------
// workerpool を使用したサンプル
// -------------------------------

// ヘビーな処理をシミュレートするタスク
func processingTask(id int) (string, error) {
	fmt.Printf("Task %d: Starting...\n", id)
	
	// ランダムな処理時間
	duration := time.Duration(rand.Intn(1000)+500) * time.Millisecond
	time.Sleep(duration)
	
	// ランダムに成功または失敗
	if rand.Intn(10) < 1 {
		return "", fmt.Errorf("task %d failed", id)
	}
	
	result := fmt.Sprintf("Result from task %d (took %v)", id, duration)
	fmt.Printf("Task %d: Completed\n", id)
	return result, nil
}

// workerpool を使用したワーカープールの例
func demonstrateWorkerpool() {
	fmt.Println("\n=== workerpool Example ===")
	
	// 最大3つのワーカーを持つプール
	wp := workerpool.New(3)
	defer wp.Stop()
	
	taskCount := 10
	var (
		results = make([]string, taskCount)
		mu      sync.Mutex
		wg      sync.WaitGroup
	)
	
	fmt.Printf("Submitting %d tasks to a pool of 3 workers...\n", taskCount)
	
	for i := 0; i < taskCount; i++ {
		i := i // ループ変数をキャプチャ
		wg.Add(1)
		
		// タスクをワーカープールに送信
		wp.Submit(func() {
			defer wg.Done()
			
			res, err := processingTask(i)
			mu.Lock()
			defer mu.Unlock()
			
			if err != nil {
				results[i] = fmt.Sprintf("Error: %v", err)
			} else {
				results[i] = res
			}
		})
	}
	
	// すべてのタスクが完了するのを待機
	wg.Wait()
	
	fmt.Println("\nAll tasks completed. Results:")
	for i, result := range results {
		fmt.Printf(" - Task %d: %s\n", i, result)
	}
	
	// ワーカープールの統計情報
	fmt.Printf("\nWorker pool statistics - Workers: %d\n", wp.Size())
}

// -------------------------------
// コンテキストキャンセレーションの例
// -------------------------------

func demonstrateContextCancellation() {
	fmt.Println("\n=== Context Cancellation Example ===")
	
	// 3秒後にキャンセルされるコンテキスト
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	
	// errgroup を使用して、キャンセル対応のタスク群を実行
	g, gCtx := errgroup.WithContext(ctx)
	
	// 長時間実行タスク
	for i := 0; i < 5; i++ {
		i := i
		g.Go(func() error {
			return longRunningTask(gCtx, i)
		})
	}
	
	// 1.5秒後に別のgoroutineからキャンセル
	go func() {
		time.Sleep(1500 * time.Millisecond)
		fmt.Println("Manually cancelling all tasks...")
		cancel()
	}()
	
	if err := g.Wait(); err != nil {
		if errors.Is(err, context.Canceled) {
			fmt.Println("Tasks were cancelled as expected")
		} else {
			fmt.Printf("Error: %v\n", err)
		}
	}
}

// コンテキストに対応した長時間実行タスク
func longRunningTask(ctx context.Context, id int) error {
	fmt.Printf("Long-running task %d started\n", id)
	ticker := time.NewTicker(300 * time.Millisecond)
	defer ticker.Stop()
	
	for i := 0; ; i++ {
		select {
		case <-ctx.Done():
			fmt.Printf("Task %d cancelled after %d iterations\n", id, i)
			return ctx.Err()
		case <-ticker.C:
			fmt.Printf("Task %d iteration %d\n", id, i)
			// エラーをシミュレート（稀に）
			if rand.Intn(30) == 0 {
				return fmt.Errorf("random error in task %d", id)
			}
		}
	}
}

// -------------------------------
// HTTP サーバのグレースフルシャットダウン例
// -------------------------------

func demoGracefulShutdown() {
	fmt.Println("\n=== Graceful Shutdown Example ===")
	
	// メインコンテキスト
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	
	// シンプルなHTTPハンドラ
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "Hello from server")
	})
	
	server := &http.Server{
		Addr: ":8080",
	}
	
	// サーバを別のgoroutineで起動
	go func() {
		fmt.Println("Starting HTTP server on :8080")
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			fmt.Printf("HTTP server error: %v\n", err)
		}
	}()
	
	// 3秒後にシャットダウンをシミュレート
	time.AfterFunc(3*time.Second, func() {
		fmt.Println("Initiating graceful shutdown...")
		
		// シャットダウンのコンテキスト（タイムアウト付き）
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer shutdownCancel()
		
		if err := server.Shutdown(shutdownCtx); err != nil {
			fmt.Printf("Server shutdown error: %v\n", err)
		} else {
			fmt.Println("Server gracefully stopped")
		}
		
		// メインキャンセルを呼び出して、プログラム全体を終了
		cancel()
	})
	
	// メインコンテキストがキャンセルされるまで待機
	<-ctx.Done()
	fmt.Println("Main context done, service exited")
}

func main() {
	// 乱数のシードを初期化
	rand.Seed(time.Now().UnixNano())
	
	fmt.Println("===== Goroutine Management with Libraries =====")
	
	// errgroup の例
	demonstrateErrGroup()
	
	// workerpool の例
	demonstrateWorkerpool()
	
	// コンテキストキャンセレーションの例
	demonstrateContextCancellation()
	
	// HTTP サーバのグレースフルシャットダウン（コメントアウト）
	// demoGracefulShutdown() 
	
	fmt.Println("\nAll examples completed")
}