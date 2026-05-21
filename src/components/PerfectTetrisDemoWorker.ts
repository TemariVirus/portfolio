const ROWS = 6;
const COLUMNS = 10;

class Wasm {
    exports: any;

    constructor(module: WebAssembly.Module) {
        const instance = new WebAssembly.Instance(module, {
            env: {
                _consoleLog: (ptr: number, len: number) => {
                    const message = this.readWasmString(ptr, len);
                    console.log(message);
                },
                _consoleError: (ptr: number, len: number) => {
                    const message = this.readWasmString(ptr, len);
                    console.error(message);
                },
            },
        });
        this.exports = instance.exports;
    }

    memoryDataView() {
        return new DataView(new Uint8Array(this.exports.memory.buffer).buffer);
    }

    readWasmString(ptr: number, len: number) {
        return new TextDecoder("utf-8").decode(
            this.memoryDataView().buffer.slice(ptr, ptr + len)
        );
    }

    sendWasmString(str: string) {
        const encoder = new TextEncoder();
        const encoded = encoder.encode(str);
        const ptr: number = this.exports.ensureBufferSize(encoded.length);

        const memory = this.memoryDataView();
        for (let i = 0; i < encoded.length; i++) {
            memory.setUint8(ptr + i, encoded[i]!);
        }
        return { ptr: ptr, len: encoded.length };
    }
}

function findPc(wasm: Wasm, board: boolean[], queue: string): string[] | null {
    const { ptr, len } = wasm.sendWasmString(
        board.map((b) => (b ? "G" : "N")).join("") + queue
    );
    const solution_ptr = wasm.exports.findPc(ptr, len);
    if (solution_ptr === 0) return null;

    const frame_count = wasm.memoryDataView().getUint8(solution_ptr);
    const solution_frames = [];
    for (let i = 0; i < frame_count; i++) {
        solution_frames.push(
            wasm.readWasmString(
                solution_ptr + 8 + ROWS * COLUMNS * i,
                ROWS * COLUMNS
            )
        );
    }
    return solution_frames;
}

self.onmessage = (e) => {
    const {
        wasmModule,
        board,
        queue,
    }: { wasmModule: WebAssembly.Module; board: boolean[]; queue: string } =
        e.data;
    const instance = new Wasm(wasmModule);

    const start = performance.now();
    const solution_frames = findPc(instance, board, queue);
    const time_taken = performance.now() - start;

    self.postMessage({
        time: time_taken,
        frames: solution_frames,
    });
};
