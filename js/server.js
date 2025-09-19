
// ============================================================================
// EXAMPLE FILE
// ----------------------------------------------------------------------------
// Used as an example of how to bridge to your SDK/WASM
// ============================================================================
//
//

'use strict';

const express = require('express');
const app = express();

app.use(express.json({ limit: '1mb' }));
app.use('/kisr', require('./router'));

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`KISR server listening on :${PORT}`));
