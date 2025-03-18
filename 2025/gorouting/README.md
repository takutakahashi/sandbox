# Goroutine の生存期間に関する検証

このリポジトリでは、Golangのgoroutineの生存期間と挙動について検証しています。特に、親関数が終了した後のgoroutineの状態や変数の参照に焦点を当てています。

## 検証内容

5つのサンプルコードを通して、以下の内容を検証しています：

1. **基本的な生存期間の検証** (`goroutine_lifecycle.go`)
2. **複数goroutineと変数キャプチャの検証** (`goroutine_detailed.go`)
3. **メモリとガベージコレクションの挙動検証** (`goroutine_memory.go`)
4. **チャネルを使ったgoroutine管理** (`goroutine_channels.go`)
5. **ライブラリを使用したgoroutine管理** (`goroutine_libraries.go`)

## 主な発見

### 1. Goroutineの生存期間

- **親関数が終了しても、goroutineは継続実行される**
  - 親関数のスコープに縛られず、プログラムが終了するまで実行を継続
  - `go func() { ... }()` で起動したgoroutineは、その呼び出し元の関数が終了した後も継続して動作する

- **メインプログラム終了時の挙動**
  - メインプログラム（main関数）が終了すると、実行中のすべてのgoroutineは強制的に終了する
  - つまり、どんなに長いgoroutineも、プログラム自体が終了すれば一緒に終了する

### 2. 変数へのアクセス

- **クロージャとしてのgoroutine**
  - goroutineは親関数のローカル変数をクロージャとしてキャプチャできる
  - 親関数が終了した後も、そのローカル変数にアクセスできる

- **変数のメモリ管理**
  - goroutineによってキャプチャされた変数は、自動的にヒープメモリに「エスケープ」される
  - 通常なら親関数終了と共に解放されるスタック変数が、goroutineからアクセス可能な状態で保持される

### 3. 実用上の考慮点

- **終了条件の設定**
  - 無限ループするgoroutineには、適切な終了条件を設けるべき
  - `context`パッケージを使ったキャンセレーションやチャネルを使った停止シグナルが一般的

- **リソースリークの防止**
  - 適切に終了されないgoroutineはリソースリークの原因になる
  - 特にWebサーバーなど長期間動作するアプリケーションでは重要

## サンプルコードの解説

### 1. `goroutine_lifecycle.go`

基本的なgoroutineの生存期間を検証するコード。無限ループを実行するgoroutineを起動し、親関数とメインプログラムが終了するまでの挙動を観察します。

```go
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
```

### 2. `goroutine_detailed.go`

複数のgoroutineの相互作用と変数キャプチャを検証するコード。親関数のローカル変数を参照するgoroutineや、WaitGroupで制御されたgoroutineの挙動を観察します。

### 3. `goroutine_memory.go`

メモリ管理とガベージコレクションの観点からgoroutineを検証するコード。親関数のスタックフレームが消えた後も、goroutineが変数にアクセスできる仕組みを確認します。

### 4. `goroutine_channels.go`

チャネルを使った実用的なgoroutine管理パターンを実装したコード。WorkerパターンとWorkerPoolパターンを用いて、複数のgoroutineを適切に制御する方法を示しています。

```go
// Workerは停止シグナル用のdoneChanと結果送信用のresultChanを持つ
type Worker struct {
    ID         int
    doneChan   chan struct{}  // 終了シグナル用チャネル
    resultChan chan<- string  // 結果送信用チャネル
    wg         *sync.WaitGroup
}

// Start メソッドはgoroutineを起動し、doneChanで終了シグナルを受信するまで実行
func (w *Worker) Start() {
    w.wg.Add(1)
    
    go func() {
        defer w.wg.Done()
        
        // ...
        
        for {
            select {
            case <-w.doneChan:
                // 終了シグナルを受信
                return
            case <-ticker.C:
                // 通常の処理
                // ...
            }
        }
    }()
}
```

### 5. `goroutine_libraries.go`

サードパーティライブラリを使用したgoroutine管理の例です。特に `errgroup` と `workerpool` の2つのライブラリの使用方法と特徴を示しています。

```go
// errgroup を使ったエラー伝播と一括キャンセル
func fetchWithErrGroup(ctx context.Context, apiCount int) ([]string, error) {
    g, gCtx := errgroup.WithContext(ctx)
    results := make([]string, apiCount)
    
    for i := 0; i < apiCount; i++ {
        i := i // ループ変数をキャプチャ
        
        g.Go(func() error {
            data, err := fetchAPI(gCtx, i)
            if err != nil {
                return err // エラーが発生すると他のgoroutineもキャンセルされる
            }
            
            results[i] = data
            return nil
        })
    }
    
    // すべてのgoroutineが完了するか、エラーが発生するまで待機
    if err := g.Wait(); err != nil {
        return nil, err
    }
    
    return results, nil
}

// workerpool を使った同時実行数の制限
wp := workerpool.New(3) // 最大3つのgoroutineで処理
defer wp.Stop()

for i := 0; i < taskCount; i++ {
    i := i
    wp.Submit(func() {
        // ワーカープールで実行されるタスク
        // ...
    })
}
```

## 実用的なパターン

### 1. コンテキストを使った制御

```go
func controlledTask(ctx context.Context) {
    go func() {
        for {
            select {
            case <-ctx.Done():
                fmt.Println("Goroutine: Received cancellation signal, stopping")
                return
            default:
                // 通常の処理
                time.Sleep(1 * time.Second)
            }
        }
    }()
}

func main() {
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()
    
    controlledTask(ctx)
    // 5秒後にgoroutineは自動的に終了する
}
```

### 2. チャネルを使った制御

```go
func startWorker(done <-chan struct{}) {
    go func() {
        for {
            select {
            case <-done:
                fmt.Println("Worker: Stopping as requested")
                return
            default:
                // 通常の処理
                time.Sleep(1 * time.Second)
            }
        }
    }()
}

func main() {
    done := make(chan struct{})
    
    startWorker(done)
    
    // 3秒後にworkerを停止
    time.Sleep(3 * time.Second)
    close(done)
}
```

## 結論

- goroutineは親関数のスコープとは独立して実行を継続する
- 変数キャプチャによって親関数のローカル変数にもアクセスできる
- メインプログラム終了時には全てのgoroutineも強制終了される
- 適切な終了制御を行わないと、リソースリークの原因となる可能性がある

この検証を通じて、goroutineの特性をよく理解し、適切に制御することの重要性が示されました。Goの並行処理モデルを効果的に活用するためには、これらの特性を考慮したプログラミングが必要です。

## 実用: チャネルを使ったgoroutine管理パターン

`goroutine_channels.go` で示した Worker/WorkerPool パターンは、実際のアプリケーションで利用できる実践的なgoroutine管理手法です。

### 主要なコンセプト

1. **終了シグナル用チャネル**
   - `doneChan` のような専用のチャネルを使って、goroutineに停止を通知
   - `close(doneChan)` で全ての受信側に同時に通知できる
   - `struct{}{}` は0バイトのため、メモリ効率が良い

2. **戻り値の伝達**
   - `resultChan` により、goroutineからメイン処理への結果の伝達を実現
   - 方向指定付きチャネル（`chan<-` や `<-chan`）で意図を明確に

3. **同期と完了待機**
   - `sync.WaitGroup` で複数のgoroutineの完了を待機
   - きちんと `.Done()` が呼ばれることを保証するために `defer` を使用

4. **構造化された設計**
   - `Worker` 構造体でgoroutineに関連する状態をカプセル化
   - `WorkerPool` でgoroutineのコレクションを管理

### 実装のポイント

1. **リソース管理**

```go
// リソースの確保と解放がペアになっている
ticker := time.NewTicker(1 * time.Second)
defer ticker.Stop()
```

2. **チャネル選択**

```go
for {
    select {
    case <-doneChan:
        // 終了処理
        return
    case <-ticker.C:
        // 定期的な処理
    }
}
```

3. **優雅な終了処理**

```go
// WorkerPoolの終了処理
func (wp *WorkerPool) Stop() {
    // 1. 全ワーカーに停止シグナルを送信
    for _, worker := range wp.workers {
        worker.Stop()
    }
    
    // 2. 全ワーカーの終了を待機
    wp.wg.Wait()
    
    // 3. 結果チャネルをクローズ
    close(wp.resultChan)
}
```

### 実際のユースケース

このパターンは以下のような状況で特に有用です：

- バックグラウンドでのバッチ処理
- 複数のAPIへの並行リクエスト
- 同時実行数を制限したい並列タスク
- 長時間実行されるサービスでのリソース管理

### 注意点

- チャネルのクローズは送信側が行い、受信側が行わないようにする
- `close()` を複数回呼ぶとパニックになるため注意
- バッファ付きチャネルを適切に使い、デッドロックを防ぐ
- 同一チャネルで送受信を行う場合、デッドロックに注意

## ライブラリを使ったgoroutine管理

`goroutine_libraries.go` で実装した例では、標準ライブラリだけでなくサードパーティのライブラリを使用してgoroutineを管理する手法を示しています。これらのライブラリは、goroutineの制御をより簡単かつ堅牢に行うための抽象化を提供します。

### 主要なライブラリ

#### 1. golang.org/x/sync/errgroup

`errgroup`パッケージは標準の`sync.WaitGroup`を拡張し、以下の機能を提供します：

- **エラー伝播**: いずれかのgoroutineでエラーが発生した場合、そのエラーを返す
- **コンテキスト連携**: エラー発生時に他のgoroutineを自動的にキャンセル
- **構造化された並行処理**: 依存関係のあるタスクを簡潔に記述

```go
func Example() error {
    g, ctx := errgroup.WithContext(context.Background())
    
    // 複数のタスクをgoroutineで実行
    for _, url := range urls {
        url := url  // ループ変数をキャプチャする重要性
        g.Go(func() error {
            // ctx がキャンセルされると、他のgoroutineも停止する
            resp, err := http.Get(url)
            if err != nil {
                return err  // このエラーがg.Wait()の戻り値になる
            }
            resp.Body.Close()
            return nil
        })
    }
    
    // すべてのgoroutineが完了するか、エラーが発生するまで待機
    return g.Wait()
}
```

#### 2. github.com/gammazero/workerpool

`workerpool`は同時実行数を制限したgoroutineプールを提供します：

- **同時実行数の制限**: リソース使用量をコントロール
- **ジョブキューイング**: タスクが多い場合でも実行数を一定に
- **再利用可能なワーカー**: goroutineの生成/破棄コストを削減

```go
func Example() {
    // 最大5つのgoroutineで処理
    wp := workerpool.New(5)
    defer wp.Stop()
    
    // 1000個のタスクを登録（同時に5つまで実行）
    for i := 0; i < 1000; i++ {
        i := i
        wp.Submit(func() {
            // ワークロードの処理
            processItem(i)
        })
    }
    
    // プールを停止すると、残りのタスクが完了するのを待機
    wp.StopWait()
}
```

### ライブラリを使うメリット

1. **コード量削減**: 多くのボイラープレートコードを省略
2. **エラーハンドリング**: 複雑なエラー処理を簡潔に
3. **リソース管理**: メモリやCPU使用率のコントロール
4. **ベストプラクティス**: 洗練されたパターンの活用

### 実装例の詳細解説

#### errgroup によるエラー伝播とキャンセル

`errgroup`の主な特徴は、あるgoroutineでエラーが発生した場合に他のgoroutineも終了させられることです：

```go
// errgroup は 1つのgoroutineでエラーが発生すると
// コンテキストをキャンセルして他のgoroutineにも通知する
g, gCtx := errgroup.WithContext(ctx)

// 複数のgoroutineを起動
for i := 0; i < apiCount; i++ {
    i := i
    g.Go(func() error {
        // gCtx は親goroutineでエラーが発生するとキャンセルされる
        data, err := fetchAPI(gCtx, i)
        if err != nil {
            return err  // このエラーによって他のgoroutineも停止する
        }
        
        results[i] = data
        return nil
    })
}
```

この例では、1つのAPIリクエストが失敗すると、他のリクエストもキャンセルされます。これは、障害が発生した場合にリソースを浪費しないために有用です。

#### workerpool による同時実行制御

`workerpool`の主な利点は、大量のタスクがある場合でも同時実行数を制限できることです：

```go
// 3つのgoroutineだけを使って10個のタスクを処理
wp := workerpool.New(3)
defer wp.Stop()

// 10個のタスクを登録（同時に3つまで実行）
for i := 0; i < taskCount; i++ {
    i := i
    wp.Submit(func() {
        // タスク処理
        res, err := processingTask(i)
        
        mu.Lock()
        defer mu.Unlock()
        results[i] = res  // 結果を保存
    })
}
```

これにより、大量のgoroutineを一度に起動してリソースを使い果たすことなく、タスクを効率的に処理できます。

#### コンテキストを活用したキャンセル

`context`パッケージと組み合わせることで、タイムアウトやキャンセル処理も容易になります：

```go
// タイムアウトとキャンセルに対応した例
ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
defer cancel()

g, gCtx := errgroup.WithContext(ctx)

// ユーザーからのキャンセル（例えばCtrl+C）をシミュレート
go func() {
    time.Sleep(1 * time.Second)
    fmt.Println("Operation cancelled by user")
    cancel()  // すべてのgoroutineに通知される
}()
```

### 実際のアプリケーションでの応用

これらのライブラリは、以下のような実際のシナリオで特に有用です：

1. **Webサーバー**: 複数のリクエストを同時に処理する際の制御
2. **データ処理パイプライン**: 大量データを並列処理する際のスループットコントロール
3. **バッチジョブ**: 何千ものタスクを効率よく処理
4. **マイクロサービス**: 複数のAPIへの並列リクエスト
5. **ファイルシステム操作**: 多数のファイル操作を並行実行