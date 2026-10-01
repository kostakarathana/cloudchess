// Compile Stockfish's upstream optimized NNUE implementation separately. Its
// types/symbols never cross the bridge, and unsupported CPUs never enter it.
#define CC_DOTPROD_VARIANT 1
#define Stockfish StockfishDotprod
#define CCChess CCDotprodChess
#define CCStop CCDotprodStop
#define CCBackgroundEpoch CCDotprodBackgroundEpoch
#define CCStopBackground CCDotprodStopBackground
#include "ChessBridge.mm"
