# Cuadra Fabric

A Next.js application with Vercel Web Analytics integration.

## Getting Started

First, install the dependencies:

```bash
npm install
```

Then, run the development server:

```bash
npm run dev
```

Open [http://localhost:3000](http://localhost:3000) with your browser to see the result.

## Vercel Web Analytics

This project has been configured with Vercel Web Analytics. The `@vercel/analytics` package is installed and the `<Analytics />` component has been added to the root layout.

### What's Included

- **@vercel/analytics package**: Installed and configured
- **Analytics Component**: Added to `app/layout.tsx` for automatic page view tracking
- **Framework**: Next.js 15 with App Router
- **TypeScript**: Full TypeScript support

### Enabling Analytics on Vercel

To start collecting analytics data:

1. Deploy this application to Vercel
2. Navigate to your project's dashboard on Vercel
3. Go to the Analytics tab
4. Click the "Enable" button to activate Web Analytics

Once enabled, Vercel will automatically start collecting page views and web vitals data.

## Project Structure

```
cuadra-fabric/
├── app/
│   ├── layout.tsx      # Root layout with Analytics component
│   ├── page.tsx        # Home page
│   └── globals.css     # Global styles
├── package.json
├── tsconfig.json
├── next.config.js
└── README.md
```

## Build and Deploy

Build the project:

```bash
npm run build
```

Start the production server:

```bash
npm start
```

Deploy to Vercel:

```bash
npm install -g vercel
vercel
```

## Learn More

- [Next.js Documentation](https://nextjs.org/docs)
- [Vercel Web Analytics Documentation](https://vercel.com/docs/analytics/quickstart)
